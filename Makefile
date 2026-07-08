RACO ?= raco
PYTHON ?= python3
REALBENCH_VENV ?= .venv-realbench
REALBENCH_PYTHON := $(REALBENCH_VENV)/bin/python
REALBENCH_MODEL_ID ?= Qwen/Qwen3.5-4B
REALBENCH_MODEL_DIR ?= /mnt/storage/models/qwen/Qwen3.5-4B
REALBENCH_SIDECAR ?= $(REALBENCH_PYTHON) experiments/012_real_model_benchmark/code/hf_logits_sidecar.py --model-path $(REALBENCH_MODEL_DIR)
REALBENCH_HARD_PILOT_TIMEOUT ?= 600s
REALBENCH_HARD_SAMPLE_TIMEOUT_SEC ?= 60

.PHONY: help install lint compile arch-lint dep-lint ci test realbench-env realbench-check realbench-test realbench-sidecar-smoke realbench-hard-pilot

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Install the Racket package with raco.' \
	  '  make compile       Compile the library and tests.' \
	  '  make arch-lint     Report module size/surface and check architecture rules.' \
	  '  make dep-lint      Check architecture and actionable unused requires.' \
	  '  make lint          Run compile and dependency lint.' \
	  '  make test          Run contract and real sidecar e2e tests.' \
	  '  make realbench-env        Create/check real benchmark venv, download model, smoke CUDA.' \
	  '  make realbench-check      Check existing real benchmark backend without install/download.' \
	  '  make realbench-test       Run Experiment 012 tests with the realbench venv.' \
	  '  make realbench-sidecar-smoke Check Racket <-> HF sidecar generation.' \
	  '  make realbench-hard-pilot Run hard filter pilot with the realbench backend.' \
	  '  make ci            Run lint and tests.'

install:
	$(RACO) pkg install --auto

compile:
	$(RACO) make main.rkt model-qwen.rkt tests/contract-test.rkt tests/e2e-real-test.rkt tests/e2e-sampler-test.rkt tests/private/sampling-test.rkt tests/private/runtime-test.rkt

arch-lint:
	RACO="$(RACO)" racket tools/arch-lint.rkt

dep-lint: arch-lint

lint: compile dep-lint

ci: lint test

test:
	$(RACO) test tests

realbench-env:
	$(PYTHON) experiments/012_real_model_benchmark/code/setup_real_backend.py \
	  --venv $(REALBENCH_VENV) \
	  --model-id $(REALBENCH_MODEL_ID) \
	  --model-dir $(REALBENCH_MODEL_DIR) \
	  --install \
	  --download \
	  --smoke \
	  --no-write

realbench-check:
	$(PYTHON) experiments/012_real_model_benchmark/code/setup_real_backend.py \
	  --venv $(REALBENCH_VENV) \
	  --model-dir $(REALBENCH_MODEL_DIR) \
	  --smoke \
	  --no-write

realbench-test:
	$(REALBENCH_PYTHON) experiments/012_real_model_benchmark/code/test_real_model_benchmark.py

realbench-sidecar-smoke:
	racket experiments/012_real_model_benchmark/code/racket_sidecar_smoke.rkt \
	  --model-path $(REALBENCH_MODEL_DIR) \
	  --sidecar-command "$(REALBENCH_SIDECAR)"

realbench-hard-pilot:
	RACK_LLM_MODEL_PATH=$(REALBENCH_MODEL_DIR) \
	RACK_LLM_LLAMA_SIDECAR="$(REALBENCH_SIDECAR)" \
	timeout $(REALBENCH_HARD_PILOT_TIMEOUT) \
	$(REALBENCH_PYTHON) experiments/012_real_model_benchmark/code/run_hard_runtime_benchmark.py \
	  --mode pilot \
	  --per-sample-timeout-sec $(REALBENCH_HARD_SAMPLE_TIMEOUT_SEC)
