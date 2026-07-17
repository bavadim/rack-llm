#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define RACKLLM_ENABLE_CONFORMANCE 1
#include "rackllm_llama.h"

static int32_t * tokenize(struct rackllm_llama_model * model,
                          const char * text,
                          int32_t * count) {
    *count = rackllm_llama_tokenize(model, text, (int32_t) strlen(text), NULL, 0);
    if (*count <= 0) return NULL;
    int32_t * tokens = malloc((size_t) *count * sizeof(*tokens));
    if (!tokens || rackllm_llama_tokenize(
            model, text, (int32_t) strlen(text), tokens, *count) != *count) {
        free(tokens);
        return NULL;
    }
    return tokens;
}

static void fail(const char * where, const char * error) {
    fprintf(stderr, "%s: %s\n", where, error && *error ? error : "failed");
    exit(2);
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: %s MODEL [WIDTH=8] [GPU_LAYERS=999] [CYCLES=50] "
                "[CONTEXT=768] [TARGET_LANE=0]\n", argv[0]);
        return 2;
    }
    const int32_t width = argc > 2 ? atoi(argv[2]) : 8;
    const int32_t gpu_layers = argc > 3 ? atoi(argv[3]) : 999;
    const int32_t cycles = argc > 4 ? atoi(argv[4]) : 50;
    const int32_t context = argc > 5 ? atoi(argv[5]) : 768;
    const int32_t target_lane = argc > 6 ? atoi(argv[6]) : 0;
    if (width < 1 || width > 32 || cycles < 1 || context < 8 ||
        target_lane < 0 || target_lane >= width) return 2;

    char error[2048] = {0};
    struct rackllm_llama_model * model = rackllm_llama_model_open(
        argv[1], gpu_layers, 0, error, sizeof(error));
    if (!model) fail("model-open", error);
    const int32_t vocab = rackllm_llama_vocab_size(model);
    struct rackllm_llama_batch_engine * engine = rackllm_llama_batch_engine_open(
        model, width, context, 8192, 512, 4, 16, 16, error, sizeof(error));
    if (!engine) fail("cohort-open", error);

    int32_t prompt_count = 0, target_count = 0, alpha_count = 0, beta_count = 0;
    int32_t * prompt = tokenize(model, "Reply with exactly yes or no:", &prompt_count);
    int32_t * target = tokenize(model, " yes", &target_count);
    int32_t * alpha = tokenize(model, " alpha", &alpha_count);
    int32_t * beta = tokenize(model, " beta", &beta_count);
    if (!prompt || !target || !alpha || !beta) fail("tokenize", "empty tokenization");

    int32_t * prompts = malloc((size_t) width * prompt_count * sizeof(*prompts));
    int32_t * offsets = malloc((size_t) (width + 1) * sizeof(*offsets));
    int32_t * tokens = malloc((size_t) width * sizeof(*tokens));
    float * baseline = malloc((size_t) vocab * sizeof(*baseline));
    float * replay = malloc((size_t) vocab * sizeof(*replay));
    if (!prompts || !offsets || !tokens ||
        !baseline || !replay) fail("alloc", "out of memory");
    for (int32_t lane = 0; lane < width; lane++) {
        memcpy(prompts + (size_t) lane * prompt_count, prompt,
               (size_t) prompt_count * sizeof(*prompt));
        offsets[lane] = lane * prompt_count;
    }
    offsets[width] = width * prompt_count;
    if (rackllm_llama_batch_start(engine, prompts, offsets,
                                  error, sizeof(error)) != 0) {
        fail("cohort-start", error);
    }

    for (int32_t cycle = 0; cycle < cycles; cycle++) {
        if (cycle > 0 && rackllm_llama_batch_reset(
                engine, &target_lane, 1, error, sizeof(error)) != 0) {
            fail("target-reset", error);
        }
        /* Exercise independent peer lifecycle without changing physical width. */
        if (cycle > 0 && width > 1 && cycle % 7 == 0) {
            int32_t peer = (target_lane + 1 + cycle) % width;
            if (peer == target_lane) peer = (peer + 1) % width;
            if (rackllm_llama_batch_reset(
                    engine, &peer, 1, error, sizeof(error)) != 0) {
                fail("peer-reset", error);
            }
        }
        for (int32_t lane = 0; lane < width; lane++) {
            tokens[lane] = lane == target_lane
                ? target[0] : ((cycle & 1) ? beta[0] : alpha[0]);
        }
        if (rackllm_llama_batch_commit(engine, tokens, error, sizeof(error)) != 0) {
            fail("cohort-decode", error);
        }
        float * current = cycle == 0 ? baseline : replay;
        if (rackllm_llama_batch_copy_logits(
                engine, target_lane, current, vocab) != 0) {
            fail("copy-logits", "copy failed");
        }
        if (cycle > 0) {
            int32_t changed = 0;
            float max_abs = 0.0f;
            for (int32_t id = 0; id < vocab; id++) {
                if (memcmp(baseline + id, replay + id, sizeof(float)) != 0) changed++;
                float delta = fabsf(baseline[id] - replay[id]);
                if (delta > max_abs) max_abs = delta;
            }
            if (changed != 0) {
                fprintf(stderr,
                        "FAIL cycle=%d lane=%d changed=%d/%d max_abs=%.9g\n",
                        cycle, target_lane, changed, vocab, max_abs);
                return 1;
            }
        }
    }
    if (rackllm_llama_batch_end(engine) != 0) {
        fail("cohort-end", "release failed");
    }

    /* Start a new epoch with the target request unchanged but completely
     * different peer prompts.  This catches prefill dependence on batch
     * neighbours in addition to the decode/reset churn above. */
    int32_t peer_a_count = 0, peer_b_count = 0;
    int32_t * peer_a = tokenize(model, "Unrelated neighboring prompt about alpha:",
                                &peer_a_count);
    int32_t * peer_b = tokenize(model, "A different peer request concerning beta:",
                                &peer_b_count);
    if (!peer_a || !peer_b) fail("tokenize-peers", "empty tokenization");
    int32_t mixed_count = prompt_count;
    for (int32_t lane = 1; lane < width; lane++) {
        mixed_count += (lane & 1) ? peer_a_count : peer_b_count;
    }
    int32_t * mixed = malloc((size_t) mixed_count * sizeof(*mixed));
    if (!mixed) fail("alloc-mixed", "out of memory");
    int32_t mixed_cursor = 0;
    for (int32_t lane = 0; lane < width; lane++) {
        offsets[lane] = mixed_cursor;
        const int32_t * source = lane == target_lane
            ? prompt : ((lane & 1) ? peer_a : peer_b);
        int32_t count = lane == target_lane
            ? prompt_count : ((lane & 1) ? peer_a_count : peer_b_count);
        memcpy(mixed + mixed_cursor, source, (size_t) count * sizeof(*source));
        mixed_cursor += count;
    }
    offsets[width] = mixed_cursor;
    if (rackllm_llama_batch_start(engine, mixed, offsets,
                                  error, sizeof(error)) != 0) {
        fail("mixed-cohort-start", error);
    }
    for (int32_t lane = 0; lane < width; lane++) {
        tokens[lane] = lane == target_lane
            ? target[0] : ((lane & 1) ? alpha[0] : beta[0]);
    }
    if (rackllm_llama_batch_commit(engine, tokens, error, sizeof(error)) != 0) {
        fail("mixed-cohort-decode", error);
    }
    if (rackllm_llama_batch_copy_logits(
            engine, target_lane, replay, vocab) != 0) {
        fail("mixed-copy-logits", "copy failed");
    }
    for (int32_t id = 0; id < vocab; id++) {
        if (memcmp(baseline + id, replay + id, sizeof(float)) != 0) {
            fprintf(stderr,
                    "FAIL mixed-peer-prompts lane=%d first_changed_id=%d "
                    "baseline=%.9g replay=%.9g\n",
                    target_lane, id, baseline[id], replay[id]);
            return 1;
        }
    }
    if (rackllm_llama_batch_end(engine) != 0) {
        fail("mixed-cohort-end", "release failed");
    }
    printf("PASS model=%s width=%d gpu_layers=%d cycles=%d context=%d lane=%d "
           "vocab=%d\n", argv[1], width, gpu_layers, cycles, context,
           target_lane, vocab);

    free(prompt); free(target); free(alpha); free(beta); free(peer_a); free(peer_b);
    free(mixed);
    free(prompts); free(offsets); free(tokens);
    free(baseline); free(replay);
    rackllm_llama_batch_engine_close(engine);
    rackllm_llama_model_close(model);
    return 0;
}
