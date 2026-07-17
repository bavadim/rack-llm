#ifndef RACKLLM_LLAMA_H
#define RACKLLM_LLAMA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rackllm_llama_model;
struct rackllm_llama_batch_engine;

struct rackllm_llama_model *rackllm_llama_model_open(
    const char *, int32_t, int32_t, char *, size_t);
void rackllm_llama_model_close(struct rackllm_llama_model *);
int32_t rackllm_llama_vocab_size(struct rackllm_llama_model *);
uint64_t rackllm_llama_vocab_fingerprint(struct rackllm_llama_model *);
int32_t rackllm_llama_eog_count(struct rackllm_llama_model *);
int32_t rackllm_llama_eog_ref(struct rackllm_llama_model *, int32_t);
int32_t rackllm_llama_tokenize(
    struct rackllm_llama_model *, const char *, int32_t, int32_t *, int32_t);
int32_t rackllm_llama_detokenize(
    struct rackllm_llama_model *, const int32_t *, int32_t, char *, int32_t);
int32_t rackllm_llama_token_to_piece(
    struct rackllm_llama_model *, int32_t, char *, int32_t);

struct rackllm_llama_batch_engine *rackllm_llama_batch_engine_open(
    struct rackllm_llama_model *, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, int32_t, char *, size_t);
void rackllm_llama_batch_engine_close(struct rackllm_llama_batch_engine *);
int32_t rackllm_llama_batch_start(
    struct rackllm_llama_batch_engine *, const int32_t *, const int32_t *,
    char *, size_t);
int32_t rackllm_llama_batch_reset(
    struct rackllm_llama_batch_engine *, const int32_t *, int32_t, char *, size_t);
int32_t rackllm_llama_batch_commit(
    struct rackllm_llama_batch_engine *, const int32_t *, char *, size_t);
int32_t rackllm_llama_batch_sample_factors(
    struct rackllm_llama_batch_engine *, const int32_t *, const double *,
    const int32_t *, const int32_t *, const int32_t *, const int32_t *,
    const int32_t *, const int32_t *, const double *, const double *, int32_t,
    int32_t *, double *, int32_t *);
int32_t rackllm_llama_batch_end(struct rackllm_llama_batch_engine *);

#ifdef RACKLLM_ENABLE_CONFORMANCE
int32_t rackllm_llama_batch_copy_logits(
    struct rackllm_llama_batch_engine *, int32_t, float *, int32_t);
#endif

#ifdef __cplusplus
}
#endif

#endif
