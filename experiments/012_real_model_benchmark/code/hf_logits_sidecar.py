#!/usr/bin/env python3
"""JSON-lines Hugging Face logits sidecar for rack-llm real benchmarks."""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


@dataclass
class Backend:
    model_path: Path
    device: str = "cuda"
    dtype: str = "auto"
    tokenizer: Any | None = None
    model: Any | None = None
    vocab: list[str] | None = None

    def load(self) -> dict[str, Any]:
        started = time.perf_counter()
        self.tokenizer = AutoTokenizer.from_pretrained(self.model_path, trust_remote_code=True)
        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_path,
            torch_dtype=self.dtype,
            device_map={"": self.device},
            trust_remote_code=True,
        )
        self.model.eval()
        vocab_size = int(getattr(self.model.config, "vocab_size", len(self.tokenizer)))
        self.vocab = [
            self.tokenizer.decode([token_id], clean_up_tokenization_spaces=False)
            for token_id in range(vocab_size)
        ]
        return {
            "ok": True,
            "vocab": self.vocab,
            "metadata": {
                "model_path": str(self.model_path),
                "device": str(self.model.device),
                "dtype": str(next(self.model.parameters()).dtype),
                "vocab_size": vocab_size,
                "load_seconds": time.perf_counter() - started,
                "torch": torch.__version__,
                "torch_cuda": torch.version.cuda,
                "gpu_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
            },
        }

    def require_loaded(self) -> None:
        if self.tokenizer is None or self.model is None:
            raise RuntimeError("backend is not loaded; send load first")

    def tokenize(self, text: str) -> dict[str, Any]:
        self.require_loaded()
        ids = self.tokenizer.encode(text, add_special_tokens=False)
        return {"ok": True, "ids": [int(x) for x in ids]}

    def detokenize(self, ids: list[int]) -> dict[str, Any]:
        self.require_loaded()
        return {
            "ok": True,
            "text": self.tokenizer.decode(ids, clean_up_tokenization_spaces=False),
        }

    def decode_generated(self, ids: list[int]) -> str:
        self.require_loaded()
        return self.tokenizer.decode(ids, skip_special_tokens=True, clean_up_tokenization_spaces=False)

    def next_logits(self, prompt: str, prefix: str) -> dict[str, Any]:
        self.require_loaded()
        text = prompt + prefix
        input_ids = self.tokenizer.encode(text, return_tensors="pt", add_special_tokens=False).to(self.model.device)
        if input_ids.numel() == 0:
            raise ValueError("next_logits requires non-empty prompt+prefix")
        with torch.no_grad():
            logits = self.model(input_ids=input_ids).logits[0, -1].detach().float().cpu().numpy()
        return {
            "ok": True,
            "logits_b64": encode_float64_b64(logits),
            "logits_dtype": "float64be",
            "vocab_size": int(logits.shape[0]),
        }

    def next_topk(self, prompt: str, prefix: str, k: int) -> dict[str, Any]:
        self.require_loaded()
        text = prompt + prefix
        input_ids = self.tokenizer.encode(text, return_tensors="pt", add_special_tokens=False).to(self.model.device)
        if input_ids.numel() == 0:
            raise ValueError("next_topk requires non-empty prompt+prefix")
        with torch.no_grad():
            logits = self.model(input_ids=input_ids).logits[0, -1].detach().float()
        k = max(1, min(int(k), int(logits.numel())))
        values, ids = torch.topk(logits, k=k)
        top_ids = [int(x) for x in ids.detach().cpu().tolist()]
        top_logits = [float(x) for x in values.detach().cpu().tolist()]
        top_tokens = [
            self.tokenizer.decode([token_id], clean_up_tokenization_spaces=False)
            for token_id in top_ids
        ]
        return {
            "ok": True,
            "ids": top_ids,
            "tokens": top_tokens,
            "logits": top_logits,
            "k": k,
            "vocab_size": int(logits.numel()),
        }

    def generate_unconstrained(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.require_loaded()
        samples = int(payload.get("num_return_sequences", payload.get("samples", 1)))
        if samples > 1:
            generated = self.generate_unconstrained_batch(payload)
            first = generated["samples"][0]
            return {"ok": True, **first, "samples": generated["samples"]}
        prompt = str(payload.get("prompt", ""))
        seed = int(payload.get("seed", 0))
        max_new_tokens = int(payload.get("max_tokens", payload.get("max_new_tokens", 128)))
        temperature = float(payload.get("temperature", 0.7))
        top_p = float(payload.get("top_p", 0.95))
        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
        input_ids = self.tokenizer.encode(prompt, return_tensors="pt", add_special_tokens=False).to(self.model.device)
        started = time.perf_counter()
        with torch.no_grad():
            generated = self.model.generate(
                input_ids=input_ids,
                max_new_tokens=max_new_tokens,
                do_sample=True,
                temperature=temperature,
                top_p=top_p,
                return_dict_in_generate=True,
                output_scores=True,
                pad_token_id=self.tokenizer.eos_token_id,
            )
        sequence = generated.sequences[0]
        new_ids = sequence[input_ids.shape[-1] :].tolist()
        text = self.decode_generated(new_ids)
        token_logprobs = []
        for token_id, scores in zip(new_ids, generated.scores):
            logprobs = torch.log_softmax(scores[0].float(), dim=-1)
            token_logprobs.append(float(logprobs[int(token_id)].detach().cpu()))
        return {
            "ok": True,
            "text": text,
            "ids": [int(x) for x in new_ids],
            "token_logprobs": token_logprobs,
            "lm_logprob": float(sum(token_logprobs)),
            "latency_ms": (time.perf_counter() - started) * 1000.0,
            "generated_tokens": len(new_ids),
            "finish_reason": "eos" if new_ids and new_ids[-1] == self.tokenizer.eos_token_id else "length",
        }

    def generate_unconstrained_batch(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.require_loaded()
        prompt = str(payload.get("prompt", ""))
        seed = int(payload.get("seed", 0))
        samples = int(payload.get("num_return_sequences", payload.get("samples", 1)))
        max_new_tokens = int(payload.get("max_tokens", payload.get("max_new_tokens", 128)))
        temperature = float(payload.get("temperature", 0.7))
        top_p = float(payload.get("top_p", 0.95))
        if samples < 1:
            raise ValueError("samples must be positive")
        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
        encoded = self.tokenizer(prompt, return_tensors="pt", add_special_tokens=False).to(self.model.device)
        input_ids = encoded["input_ids"].repeat(samples, 1)
        attention_mask = encoded.get("attention_mask")
        if attention_mask is not None:
            attention_mask = attention_mask.repeat(samples, 1)
        started = time.perf_counter()
        with torch.no_grad():
            generated = self.model.generate(
                input_ids=input_ids,
                attention_mask=attention_mask,
                max_new_tokens=max_new_tokens,
                do_sample=True,
                temperature=temperature,
                top_p=top_p,
                return_dict_in_generate=True,
                output_scores=True,
                pad_token_id=self.tokenizer.eos_token_id,
            )
        output = []
        prompt_len = input_ids.shape[-1]
        for sample_index, sequence in enumerate(generated.sequences):
            new_ids = sequence[prompt_len:].tolist()
            token_logprobs = []
            for token_id, scores in zip(new_ids, generated.scores):
                logprobs = torch.log_softmax(scores[sample_index].float(), dim=-1)
                token_logprobs.append(float(logprobs[int(token_id)].detach().cpu()))
            output.append(
                {
                    "sample_index": sample_index,
                    "text": self.decode_generated(new_ids),
                    "ids": [int(x) for x in new_ids],
                    "token_logprobs": token_logprobs,
                    "lm_logprob": float(sum(token_logprobs)),
                    "latency_ms": (time.perf_counter() - started) * 1000.0,
                    "generated_tokens": len(new_ids),
                    "finish_reason": "eos" if new_ids and new_ids[-1] == self.tokenizer.eos_token_id else "length",
                }
            )
        return {"ok": True, "samples": output}


def encode_float64_b64(values: np.ndarray) -> str:
    be = np.asarray(values, dtype=">f8")
    return base64.b64encode(be.tobytes()).decode("ascii")


def handle(backend: Backend, payload: dict[str, Any]) -> dict[str, Any]:
    op = payload.get("op")
    if op == "load":
        model_path = payload.get("model_path")
        if model_path:
            backend.model_path = Path(model_path)
        return backend.load()
    if op == "tokenize":
        return backend.tokenize(str(payload.get("text", "")))
    if op == "detokenize":
        return backend.detokenize([int(x) for x in payload.get("ids", [])])
    if op == "next_logits":
        return backend.next_logits(str(payload.get("prompt", "")), str(payload.get("prefix", "")))
    if op == "next_topk":
        return backend.next_topk(
            str(payload.get("prompt", "")),
            str(payload.get("prefix", "")),
            int(payload.get("k", 128)),
        )
    if op == "generate_unconstrained":
        return backend.generate_unconstrained(payload)
    if op == "generate_unconstrained_batch":
        return backend.generate_unconstrained_batch(payload)
    if op == "close":
        return {"ok": True, "closing": True}
    raise ValueError(f"unknown op: {op!r}")


def serve(model_path: Path, device: str, dtype: str) -> int:
    backend = Backend(model_path=model_path, device=device, dtype=dtype)
    for line in sys.stdin:
        try:
            payload = json.loads(line)
            response = handle(backend, payload)
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)
            if payload.get("op") == "close":
                return 0
        except Exception as error:  # noqa: BLE001 - sidecar must serialize failures.
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), flush=True)
    return 0


def self_test(model_path: Path, device: str, dtype: str, prompt: str) -> dict[str, Any]:
    backend = Backend(model_path=model_path, device=device, dtype=dtype)
    load = backend.load()
    ids = backend.tokenize(prompt)["ids"]
    text = backend.detokenize(ids)["text"]
    logits = backend.next_logits(prompt, "")
    sample = backend.generate_unconstrained(
        {"prompt": prompt, "seed": 0, "max_tokens": 4, "temperature": 0.7, "top_p": 0.95}
    )
    return {
        "ok": True,
        "load_metadata": load["metadata"],
        "roundtrip_prefix_match": text == prompt,
        "token_count": len(ids),
        "logits_vocab_size": logits["vocab_size"],
        "logits_b64_bytes": len(logits["logits_b64"]),
        "sample_text": sample["text"],
        "sample_generated_tokens": sample["generated_tokens"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, default=Path("/mnt/storage/models/qwen/Qwen3.5-4B"))
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--dtype", default="auto")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--prompt", default="Say one word.")
    args = parser.parse_args(argv)
    if args.self_test:
        print(json.dumps(self_test(args.model_path, args.device, args.dtype, args.prompt), indent=2, sort_keys=True))
        return 0
    return serve(args.model_path, args.device, args.dtype)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
