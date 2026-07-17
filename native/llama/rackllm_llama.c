#include <stdbool.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rackllm_llama.h"
#ifdef _OPENMP
#include <omp.h>
#endif

#include "llama.h"

struct rackllm_llama_model {
    struct llama_model * model;
    const struct llama_vocab * vocab;
    int32_t vocab_size;
    int32_t * eog_tokens;
    int32_t eog_count;
};


static int backend_initialized = 0;
static bool continue_visible_log = false;

static void rackllm_log_callback(enum ggml_log_level level,
                                 const char * text,
                                 void * user_data) {
    (void) user_data;
    if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
        continue_visible_log = true;
    } else if (level == GGML_LOG_LEVEL_CONT && continue_visible_log) {
        fputs(text, stderr);
    } else if (level != GGML_LOG_LEVEL_CONT) {
        continue_visible_log = false;
    }
}

static void set_error(char * err, size_t err_len, const char * message) {
    if (err == NULL || err_len == 0) {
        return;
    }
    snprintf(err, err_len, "%s", message);
}

static void ensure_backend(void) {
    if (!backend_initialized) {
        llama_log_set(rackllm_log_callback, NULL);
        llama_backend_init();
        backend_initialized = 1;
    }
}

struct rackllm_llama_model *
rackllm_llama_model_open(const char * path_model,
                         int32_t gpu_layers,
                         int32_t vocab_only,
                         char * err,
                         size_t err_len) {
    ensure_backend();
    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = gpu_layers;
    mparams.vocab_only = vocab_only != 0;
    mparams.use_mmap = true;

    struct llama_model * model = llama_model_load_from_file(path_model, mparams);
    if (model == NULL) {
        set_error(err, err_len, "llama_model_load_from_file failed");
        return NULL;
    }

    struct rackllm_llama_model * handle =
        (struct rackllm_llama_model *) calloc(1, sizeof(struct rackllm_llama_model));
    if (handle == NULL) {
        llama_model_free(model);
        set_error(err, err_len, "calloc model handle failed");
        return NULL;
    }

    handle->model = model;
    handle->vocab = llama_model_get_vocab(model);
    handle->vocab_size = llama_vocab_n_tokens(handle->vocab);
    handle->eog_tokens = (int32_t *) malloc((size_t) handle->vocab_size * sizeof(int32_t));
    if (handle->eog_tokens == NULL) {
        llama_model_free(model);
        free(handle);
        set_error(err, err_len, "allocating EOG token table failed");
        return NULL;
    }
    handle->eog_count = 0;
    for (int32_t id = 0; id < handle->vocab_size; id++) {
        if (llama_vocab_is_eog(handle->vocab, (llama_token) id)) {
            handle->eog_tokens[handle->eog_count++] = id;
        }
    }
    if (handle->eog_count == 0) {
        free(handle->eog_tokens);
        llama_model_free(model);
        free(handle);
        set_error(err, err_len, "model vocabulary has no EOG tokens");
        return NULL;
    }
    return handle;
}

void rackllm_llama_model_close(struct rackllm_llama_model * handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->model != NULL) {
        llama_model_free(handle->model);
    }
    free(handle->eog_tokens);
    free(handle);
}

int32_t rackllm_llama_vocab_size(struct rackllm_llama_model * handle) {
    return handle->vocab_size;
}

uint64_t rackllm_llama_vocab_fingerprint(struct rackllm_llama_model * handle) {
    if (!handle) return 0;
    /* FNV-1a over token ids, byte lengths and canonical vocabulary text.  The
     * outer Racket schema fingerprint remains SHA-256; this value is a stable
     * backend identity that avoids one FFI call and one String per token. */
    uint64_t hash = UINT64_C(14695981039346656037);
    for (int32_t id = 0; id < handle->vocab_size; id++) {
        const char * text = llama_vocab_get_text(handle->vocab, (llama_token) id);
        size_t length = text ? strlen(text) : 0;
        uint32_t fields[2] = { (uint32_t) id, (uint32_t) length };
        const unsigned char * meta = (const unsigned char *) fields;
        for (size_t i = 0; i < sizeof(fields); i++) {
            hash ^= meta[i]; hash *= UINT64_C(1099511628211);
        }
        for (size_t i = 0; i < length; i++) {
            hash ^= (unsigned char) text[i]; hash *= UINT64_C(1099511628211);
        }
    }
    return hash;
}

int32_t rackllm_llama_eog_count(struct rackllm_llama_model * handle) {
    return handle ? handle->eog_count : -1;
}

int32_t rackllm_llama_eog_ref(struct rackllm_llama_model * handle, int32_t index) {
    if (!handle || index < 0 || index >= handle->eog_count) return -1;
    return handle->eog_tokens[index];
}

int32_t rackllm_llama_tokenize(struct rackllm_llama_model * handle,
                               const char * text,
                               int32_t text_len,
                               int32_t * out,
                               int32_t out_len) {
    int32_t n = llama_tokenize(handle->vocab, text, text_len, out, out_len, false, true);
    if (n < 0) {
        return -n;
    }
    return n;
}

int32_t rackllm_llama_detokenize(struct rackllm_llama_model * handle,
                                 const int32_t * tokens,
                                 int32_t n_tokens,
                                 char * out,
                                 int32_t out_len) {
    int32_t n = llama_detokenize(handle->vocab,
                                 (const llama_token *) tokens,
                                 n_tokens,
                                 out,
                                 out_len,
                                 false,
                                 true);
    return n;
}

int32_t rackllm_llama_token_to_piece(struct rackllm_llama_model * handle,
                                     int32_t token,
                                     char * out,
                                     int32_t out_len) {
    return llama_token_to_piece(handle->vocab, token, out, out_len, 0, true);
}

/* Domain arrays arrive sorted by token id.  The factor kernel also scans the
 * vocabulary in token-id order, so binary-searching that array for every
 * vocabulary entry is unnecessary.  Sparse child factors are indexed through
 * the generation-stamped dense scratch table below and need not be sorted. */
typedef struct {
    const int32_t * ids;
    int32_t count;
    int32_t index;
} id_cursor;

static bool cursor_contains(id_cursor * cursor, int32_t id) {
    while (cursor->index < cursor->count && cursor->ids[cursor->index] < id) {
        cursor->index++;
    }
    return cursor->index < cursor->count && cursor->ids[cursor->index] == id;
}

static bool cursor_in_domain(bool include, id_cursor * cursor, int32_t id) {
    return include == cursor_contains(cursor, id);
}

/* Exact categorical draw for exp(logit / temperature) times the CARS factor.
 * out_metrics = base log-probability, base probability, frontier mass. */
static int32_t sample_factor_logits(
        const float * logits,
        int32_t vocab,
        double * weights,
        double * child_factors,
        uint32_t * child_stamps,
        uint32_t * child_generation_ptr,
        double temperature,
        int32_t domain_include,
        const int32_t * domain_ids,
        int32_t domain_count,
        int32_t constrain_to_domain,
        const int32_t * child_ids,
        const double * child_masses,
        int32_t child_count,
        double draw,
        int32_t * out_id,
        double * out_metrics) {
    if (!logits || vocab <= 0 || !weights || !child_factors || !child_stamps ||
        !child_generation_ptr || temperature <= 0.0 || !out_id || !out_metrics) return -2;

    /* The overwhelmingly common hard-only path has neither a cached child
     * factor nor a previously installed domain constraint.  Its proposal is
     * exactly the tempered base categorical distribution.  Keep the same
     * token-id summation order and inverse-CDF draw as the general path, but
     * calculate exp() once and retain each weight for selection instead of
     * recomputing it in a third vocabulary scan. */
    if (!constrain_to_domain && child_count == 0) {
        double max_base = -INFINITY;
        int32_t candidates = 0;
        for (int32_t id = 0; id < vocab; id++) {
            double base = (double) logits[id] / temperature;
            weights[id] = base;
            if (!isfinite(base)) continue;
            if (base > max_base) max_base = base;
            candidates++;
        }
        if (candidates == 0 || !isfinite(max_base)) return -1;

        double base_sum = 0.0;
        double frontier_sum = 0.0;
        id_cursor domain = { domain_ids, domain_count, 0 };
        for (int32_t id = 0; id < vocab; id++) {
            double base = weights[id];
            if (!isfinite(base)) {
                weights[id] = base_sum;
                continue;
            }
            double weight = exp(base - max_base);
            base_sum += weight;
            weights[id] = base_sum;
            if (cursor_in_domain(domain_include != 0, &domain, id)) {
                frontier_sum += weight;
            }
        }

        double target = fmin(fmax(draw, 0.0), 0.9999999999999999) * base_sum;
        int32_t low = 0, high = vocab;
        while (low < high) {
            int32_t middle = low + (high - low) / 2;
            if (weights[middle] > target) high = middle;
            else low = middle + 1;
        }
        int32_t selected = low < vocab ? low : -1;
        if (selected < 0) return -1;
        double selected_base = (double) logits[selected] / temperature;
        double log_z = max_base + log(base_sum);
        out_id[0] = selected;
        out_metrics[0] = selected_base - log_z;
        out_metrics[1] = exp(out_metrics[0]);
        out_metrics[2] = frontier_sum / base_sum;
        return candidates;
    }

    double max_base = -INFINITY, max_adjusted = -INFINITY;
    int32_t candidates = 0;
    id_cursor domain_first = { domain_ids, domain_count, 0 };
    uint32_t child_generation = ++(*child_generation_ptr);
    if (child_generation == 0) {
        memset(child_stamps, 0, (size_t) vocab * sizeof(uint32_t));
        child_generation = ++(*child_generation_ptr);
    }
    for (int32_t index = 0; index < child_count; index++) {
        int32_t id = child_ids[index];
        if (id < 0 || id >= vocab) return -2;
        child_factors[id] = child_masses[index];
        child_stamps[id] = child_generation;
    }

    for (int32_t id = 0; id < vocab; id++) {
        double base = (double) logits[id] / temperature;
        if (!isfinite(base)) {
            weights[id] = -INFINITY;
            continue;
        }
        if (base > max_base) max_base = base;
        bool frontier = cursor_in_domain(domain_include != 0, &domain_first, id);
        double mass = (constrain_to_domain && !frontier)
            ? 0.0
            : (child_stamps[id] == child_generation
               ? child_factors[id] : 1.0);
        if (mass > 0.0) {
            double adjusted = base + (mass == 1.0 ? 0.0 : log(mass));
            weights[id] = adjusted;
            if (adjusted > max_adjusted) max_adjusted = adjusted;
            candidates++;
        } else {
            weights[id] = -INFINITY;
        }
    }
    if (candidates == 0 || !isfinite(max_base) || !isfinite(max_adjusted)) return -1;

    double base_sum = 0.0, frontier_sum = 0.0, adjusted_sum = 0.0;
    id_cursor domain_second = { domain_ids, domain_count, 0 };
    for (int32_t id = 0; id < vocab; id++) {
        double base = (double) logits[id] / temperature;
        if (!isfinite(base)) {
            weights[id] = adjusted_sum;
            continue;
        }
        double base_weight = exp(base - max_base);
        base_sum += base_weight;
        bool frontier = cursor_in_domain(domain_include != 0, &domain_second, id);
        if (frontier) frontier_sum += base_weight;
        double adjusted = weights[id];
        if (isfinite(adjusted)) {
            double adjusted_weight = exp(adjusted - max_adjusted);
            adjusted_sum += adjusted_weight;
        }
        weights[id] = adjusted_sum;
    }

    double target = fmin(fmax(draw, 0.0), 0.9999999999999999) * adjusted_sum;
    int32_t low = 0, high = vocab;
    while (low < high) {
        int32_t middle = low + (high - low) / 2;
        if (weights[middle] > target) high = middle;
        else low = middle + 1;
    }
    int32_t selected = low < vocab ? low : -1;
    if (selected < 0) return -1;
    double selected_base = (double) logits[selected] / temperature;
    double log_z = max_base + log(base_sum);
    out_id[0] = selected;
    out_metrics[0] = selected_base - log_z;
    out_metrics[1] = exp(out_metrics[0]);
    out_metrics[2] = frontier_sum / base_sum;
    return candidates;
}

/* The only inference engine: one immutable-width cohort, one independent
 * llama sequence and logits row per slot. */
struct rackllm_llama_batch_engine {
    struct rackllm_llama_model * owner;
    struct llama_context * ctx;
    int32_t capacity;
    int32_t per_seq_ctx;
    int32_t n_batch;
    int32_t factor_threads;
    bool recurrent;
    bool * active;
    int32_t * pos;
    int32_t ** prompt_tokens;
    int32_t * prompt_count;
    float * logits;
    float * prompt_logits;
    double * factor_weights;
    double * child_factors;
    uint32_t * child_stamps;
    uint32_t * child_generation;
    struct llama_batch prompt_batch;
    struct llama_batch decode_batch;
    bool batches_ready;
};

void rackllm_llama_batch_engine_close(struct rackllm_llama_batch_engine * engine);

static void batch_engine_clear_slot(struct rackllm_llama_batch_engine * engine,
                                    int32_t slot) {
    llama_memory_t mem = llama_get_memory(engine->ctx);
    llama_memory_seq_rm(mem, slot, -1, -1);
    if (engine->recurrent) {
        llama_memory_seq_rm(mem, engine->capacity + slot, -1, -1);
    }
    free(engine->prompt_tokens[slot]);
    engine->prompt_tokens[slot] = NULL;
    engine->prompt_count[slot] = 0;
    engine->pos[slot] = 0;
}

struct rackllm_llama_batch_engine *
rackllm_llama_batch_engine_open(struct rackllm_llama_model * owner,
                                int32_t capacity,
                                int32_t per_seq_ctx,
                                int32_t n_batch,
                                int32_t n_ubatch,
                                int32_t threads,
                                int32_t batch_threads,
                                int32_t factor_threads,
                                char * err,
                                size_t err_len) {
    if (owner == NULL || capacity <= 0 || capacity > 32 || per_seq_ctx <= 0) {
        set_error(err, err_len, "invalid batch-engine dimensions");
        return NULL;
    }
    struct llama_context_params params = llama_context_default_params();
    bool recurrent = llama_model_is_recurrent(owner->model) ||
                     llama_model_is_hybrid(owner->model);
    params.n_seq_max = (uint32_t) (recurrent ? 2 * capacity : capacity);
    /* Hybrid prompt templates are real non-unified sequences too; size the
     * context for every owned stream so each lane keeps per_seq_ctx tokens. */
    /* llama.cpp rounds every non-unified sequence capacity to 256 tokens.
     * Round before multiplying, otherwise it first pads the aggregate and
     * then silently changes n_ctx again when splitting it into sequences. */
    const uint32_t seq_ctx = ((uint32_t) per_seq_ctx + 255u) & ~255u;
    params.n_ctx = params.n_seq_max * seq_ctx;
    params.n_batch = (uint32_t) n_batch;
    params.n_ubatch = (uint32_t) n_ubatch;
    params.n_threads = threads;
    params.n_threads_batch = batch_threads;
    params.no_perf = true;
    params.n_outputs_max = params.n_seq_max;
    /* Exact CARS revisits prefixes while peers keep advancing.  With unified
     * KV this changed cached-prefix logits on Phi, Qwen3, and Qwen3.5 on both
     * CPU and CUDA.  A fixed cohort therefore owns one physical KV stream per
     * slot for the complete numerical epoch. */
    params.kv_unified = false;

    struct llama_context * ctx = llama_init_from_model(owner->model, params);
    if (ctx == NULL) {
        set_error(err, err_len, "llama_init_from_model for batch engine failed");
        return NULL;
    }
    struct rackllm_llama_batch_engine * engine =
        (struct rackllm_llama_batch_engine *) calloc(1, sizeof(*engine));
    if (engine == NULL) {
        llama_free(ctx);
        set_error(err, err_len, "calloc batch engine failed");
        return NULL;
    }
    size_t slots = (size_t) capacity;
    size_t vocab = (size_t) owner->vocab_size;
    engine->owner = owner;
    engine->ctx = ctx;
    engine->capacity = capacity;
    engine->per_seq_ctx = per_seq_ctx;
    engine->n_batch = n_batch;
    engine->factor_threads = factor_threads > 0 ? factor_threads : 1;
    engine->recurrent = recurrent;
    engine->active = (bool *) calloc(slots, sizeof(bool));
    engine->pos = (int32_t *) calloc(slots, sizeof(int32_t));
    engine->prompt_tokens = (int32_t **) calloc(slots, sizeof(int32_t *));
    engine->prompt_count = (int32_t *) calloc(slots, sizeof(int32_t));
    engine->logits = (float *) malloc(slots * vocab * sizeof(float));
    engine->prompt_logits = (float *) malloc(slots * vocab * sizeof(float));
    engine->factor_weights = (double *) malloc(slots * vocab * sizeof(double));
    engine->child_factors = (double *) malloc(slots * vocab * sizeof(double));
    engine->child_stamps = (uint32_t *) calloc(slots * vocab, sizeof(uint32_t));
    engine->child_generation = (uint32_t *) calloc(slots, sizeof(uint32_t));
    if (!engine->active || !engine->pos || !engine->prompt_tokens ||
        !engine->prompt_count || !engine->logits || !engine->prompt_logits ||
        !engine->factor_weights ||
        !engine->child_factors || !engine->child_stamps || !engine->child_generation) {
        set_error(err, err_len, "allocating batch engine buffers failed");
        rackllm_llama_batch_engine_close(engine);
        return NULL;
    }
    engine->prompt_batch = llama_batch_init(n_batch, 0, 1);
    engine->decode_batch = llama_batch_init(capacity, 0, 1);
    engine->batches_ready = true;
    return engine;
}

void rackllm_llama_batch_engine_close(struct rackllm_llama_batch_engine * engine) {
    if (engine == NULL) return;
    if (engine->prompt_tokens != NULL) {
        for (int32_t slot = 0; slot < engine->capacity; slot++) {
            free(engine->prompt_tokens[slot]);
        }
    }
    if (engine->ctx != NULL) llama_free(engine->ctx);
    if (engine->batches_ready) {
        llama_batch_free(engine->prompt_batch);
        llama_batch_free(engine->decode_batch);
    }
    free(engine->active);
    free(engine->pos);
    free(engine->prompt_tokens);
    free(engine->prompt_count);
    free(engine->logits);
    free(engine->prompt_logits);
    free(engine->factor_weights);
    free(engine->child_factors);
    free(engine->child_stamps);
    free(engine->child_generation);
    free(engine);
}

static bool engine_same_prompt(struct rackllm_llama_batch_engine * engine,
                               int32_t slot,
                               const int32_t * prompt,
                               int32_t count) {
    return engine->prompt_tokens[slot] != NULL &&
           engine->prompt_count[slot] == count &&
           memcmp(engine->prompt_tokens[slot], prompt,
                  (size_t) count * sizeof(int32_t)) == 0;
}

static int32_t batch_engine_restore_slot(
        struct rackllm_llama_batch_engine * engine,
        int32_t slot,
        char * err,
        size_t err_len) {
    if (!engine || slot < 0 || slot >= engine->capacity ||
        !engine->active[slot] || !engine->prompt_tokens[slot]) {
        set_error(err, err_len, "invalid fixed-cohort restore slot");
        return 1;
    }
    llama_memory_t mem = llama_get_memory(engine->ctx);
    if (engine->recurrent) {
        if (!llama_memory_seq_rm(mem, slot, -1, -1)) {
            set_error(err, err_len, "clearing recurrent lane failed");
            return 1;
        }
        llama_memory_seq_cp(mem, engine->capacity + slot, slot, -1, -1);
    } else if (!llama_memory_seq_rm(mem, slot, engine->prompt_count[slot], -1)) {
        set_error(err, err_len, "clearing transformer suffix failed");
        return 1;
    }
    engine->pos[slot] = engine->prompt_count[slot];
    memcpy(engine->logits + (size_t) slot * engine->owner->vocab_size,
           engine->prompt_logits + (size_t) slot * engine->owner->vocab_size,
           (size_t) engine->owner->vocab_size * sizeof(float));
    return 0;
}

/* Prompts are flattened and offsets has capacity + 1 entries.  The fixed
 * cohort protocol maps request i to physical lane i; there is no allocator or
 * lane migration API. */
int32_t rackllm_llama_batch_start(struct rackllm_llama_batch_engine * engine,
                                  const int32_t * prompts,
                                  const int32_t * offsets,
                                  char * err,
                                  size_t err_len) {
    if (!engine || !offsets) {
        set_error(err, err_len, "invalid batch start request");
        return 1;
    }
    int32_t request_count = engine->capacity;
    int32_t * normalized = NULL;
    int32_t total = 0;
    for (int32_t request = 0; request < request_count; request++) {
        if (engine->active[request] || offsets[request + 1] < offsets[request]) {
            set_error(err, err_len, "fixed cohort is active or offsets are invalid");
            return 1;
        }
        int32_t count = offsets[request + 1] - offsets[request];
        total += count > 0 ? count : 1;
    }
    normalized = (int32_t *) malloc((size_t) total * sizeof(int32_t));
    int32_t * starts = (int32_t *) malloc((size_t) request_count * sizeof(int32_t));
    int32_t * counts = (int32_t *) malloc((size_t) request_count * sizeof(int32_t));
    bool * needs_decode = (bool *) calloc((size_t) request_count, sizeof(bool));
    int32_t * copy_from = (int32_t *) malloc((size_t) request_count * sizeof(int32_t));
    if (!normalized || !starts || !counts || !needs_decode || !copy_from) {
        free(normalized); free(starts); free(counts); free(needs_decode);
        free(copy_from);
        set_error(err, err_len, "allocating prompt batch failed"); return 1;
    }
    for (int32_t request = 0; request < request_count; request++) copy_from[request] = -1;
    int32_t cursor = 0;
    int32_t decode_count = 0;
    for (int32_t request = 0; request < request_count; request++) {
        int32_t begin = offsets[request], count = offsets[request + 1] - begin;
        starts[request] = cursor;
        if (count <= 0) {
            llama_token bos = llama_vocab_bos(engine->owner->vocab);
            if (bos < 0) {
                free(normalized); free(starts); free(counts); free(needs_decode);
                free(copy_from);
                set_error(err, err_len, "empty prompt and model has no BOS token"); return 1;
            }
            normalized[cursor++] = bos;
            count = 1;
        } else {
            memcpy(normalized + cursor, prompts + begin, (size_t) count * sizeof(int32_t));
            cursor += count;
        }
        counts[request] = count;
        int32_t slot = request;
        if (engine_same_prompt(engine, slot, normalized + starts[request], count)) {
            llama_memory_t mem = llama_get_memory(engine->ctx);
            if (engine->recurrent) {
                llama_memory_seq_rm(mem, slot, -1, -1);
                llama_memory_seq_cp(mem, engine->capacity + slot, slot, -1, -1);
            } else if (!llama_memory_seq_rm(mem, slot, count, -1)) {
                batch_engine_clear_slot(engine, slot);
                needs_decode[request] = true;
                decode_count += count;
            }
            engine->pos[slot] = count;
            memcpy(engine->logits + (size_t) slot * engine->owner->vocab_size,
                   engine->prompt_logits + (size_t) slot * engine->owner->vocab_size,
                   (size_t) engine->owner->vocab_size * sizeof(float));
        } else {
            batch_engine_clear_slot(engine, slot);
            for (int32_t prior = 0; prior < request; prior++) {
                if (counts[prior] == count &&
                    memcmp(normalized + starts[prior], normalized + starts[request],
                           (size_t) count * sizeof(int32_t)) == 0) {
                    copy_from[request] = prior;
                    break;
                }
            }
            if (copy_from[request] < 0) {
                needs_decode[request] = true;
                decode_count += count;
            }
        }
    }
    if (decode_count > engine->n_batch) {
        free(normalized); free(starts); free(counts);
        free(needs_decode); free(copy_from);
        set_error(err, err_len, "unique prompt tokens exceed n_batch");
        return 1;
    }
    if (decode_count > 0) {
        struct llama_batch * batch = &engine->prompt_batch;
        batch->n_tokens = decode_count;
        int32_t index = 0;
        int32_t * last_indices = (int32_t *) malloc((size_t) request_count * sizeof(int32_t));
        if (!last_indices) {
            free(normalized); free(starts);
            free(counts); free(needs_decode); free(copy_from);
            set_error(err, err_len, "alloc logits index failed"); return 1;
        }
        for (int32_t request = 0; request < request_count; request++) {
            last_indices[request] = -1;
            if (!needs_decode[request]) continue;
            int32_t slot = request;
            int32_t seq = engine->recurrent ? engine->capacity + slot : slot;
            for (int32_t p = 0; p < counts[request]; p++, index++) {
                batch->token[index] = normalized[starts[request] + p];
                batch->pos[index] = p;
                batch->n_seq_id[index] = 1;
                batch->seq_id[index][0] = seq;
                batch->logits[index] = p == counts[request] - 1;
                if (batch->logits[index]) last_indices[request] = index;
            }
        }
        int32_t status = llama_decode(engine->ctx, *batch);
        if (status != 0) {
            snprintf(err, err_len, "batch prompt llama_decode failed with status %d", status);
            free(last_indices); free(normalized);
            free(starts); free(counts); free(needs_decode); free(copy_from); return status;
        }
        size_t logits_bytes = (size_t) engine->owner->vocab_size * sizeof(float);
        for (int32_t request = 0; request < request_count; request++) {
            if (!needs_decode[request]) continue;
            int32_t slot = request;
            const float * logits = llama_get_logits_ith(engine->ctx, last_indices[request]);
            if (!logits) {
                set_error(err, err_len, "batch prompt logits unavailable");
                free(last_indices); free(normalized);
                free(starts); free(counts); free(needs_decode); free(copy_from); return 1;
            }
            memcpy(engine->logits + (size_t) slot * engine->owner->vocab_size,
                   logits, logits_bytes);
            memcpy(engine->prompt_logits + (size_t) slot * engine->owner->vocab_size,
                   logits, logits_bytes);
            int32_t * saved = (int32_t *) malloc((size_t) counts[request] * sizeof(int32_t));
            if (!saved) {
                set_error(err, err_len, "saving prompt tokens failed");
                free(last_indices); free(normalized);
                free(starts); free(counts); free(needs_decode); free(copy_from); return 1;
            }
            memcpy(saved, normalized + starts[request], (size_t) counts[request] * sizeof(int32_t));
            engine->prompt_tokens[slot] = saved;
            engine->prompt_count[slot] = counts[request];
            engine->pos[slot] = counts[request];
            if (engine->recurrent) {
                llama_memory_seq_cp(llama_get_memory(engine->ctx),
                                    engine->capacity + slot, slot, -1, -1);
            }
        }
        free(last_indices);
    }
    /* Decode each unique prompt once.  Requests for the same prompt receive an
     * independent KV/recurrent stream copied before generation begins. */
    size_t logits_bytes = (size_t) engine->owner->vocab_size * sizeof(float);
    for (int32_t request = 0; request < request_count; request++) {
        if (copy_from[request] < 0) continue;
        int32_t source = copy_from[request];
        int32_t slot = request;
        llama_memory_t mem = llama_get_memory(engine->ctx);
        if (engine->recurrent) {
            llama_memory_seq_cp(mem, engine->capacity + source,
                                engine->capacity + slot, -1, -1);
            llama_memory_seq_cp(mem, engine->capacity + slot, slot, -1, -1);
        } else {
            llama_memory_seq_cp(mem, source, slot, -1, -1);
        }
        int32_t * saved = (int32_t *) malloc((size_t) counts[request] * sizeof(int32_t));
        if (!saved) {
            free(normalized); free(starts); free(counts);
            free(needs_decode); free(copy_from);
            set_error(err, err_len, "saving duplicate prompt tokens failed");
            return 1;
        }
        memcpy(saved, normalized + starts[request],
               (size_t) counts[request] * sizeof(int32_t));
        engine->prompt_tokens[slot] = saved;
        engine->prompt_count[slot] = counts[request];
        engine->pos[slot] = counts[request];
        memcpy(engine->logits + (size_t) slot * engine->owner->vocab_size,
               engine->logits + (size_t) source * engine->owner->vocab_size,
               logits_bytes);
        memcpy(engine->prompt_logits + (size_t) slot * engine->owner->vocab_size,
               engine->prompt_logits + (size_t) source * engine->owner->vocab_size,
               logits_bytes);
    }
    for (int32_t request = 0; request < request_count; request++) {
        int32_t slot = request;
        engine->active[slot] = true;
    }
    free(normalized); free(starts); free(counts); free(needs_decode);
    free(copy_from);
    return 0;
}

int32_t rackllm_llama_batch_commit(struct rackllm_llama_batch_engine * engine,
                                   const int32_t * tokens,
                                   char * err,
                                   size_t err_len) {
    if (!engine || !tokens) {
        set_error(err, err_len, "fixed cohort decode requires every lane"); return 1;
    }
    int32_t count = engine->capacity;
    struct llama_batch * batch = &engine->decode_batch;
    batch->n_tokens = count;
    for (int32_t lane = 0; lane < count; lane++) {
        if (!engine->active[lane]) {
            set_error(err, err_len, "fixed cohort lane order changed");
            return 1;
        }
        if (engine->pos[lane] >= engine->per_seq_ctx &&
            batch_engine_restore_slot(engine, lane, err, err_len) != 0) {
            return 1;
        }
        batch->token[lane] = tokens[lane];
        batch->pos[lane] = engine->pos[lane];
        batch->n_seq_id[lane] = 1;
        batch->seq_id[lane][0] = lane;
        batch->logits[lane] = 1;
    }
    int32_t status = llama_decode(engine->ctx, *batch);
    if (status != 0) {
        snprintf(err, err_len, "fixed cohort llama_decode failed with status %d", status);
        return status;
    }
    size_t logits_bytes = (size_t) engine->owner->vocab_size * sizeof(float);
    for (int32_t lane = 0; lane < count; lane++) {
        const float * logits = llama_get_logits_ith(engine->ctx, lane);
        if (!logits) {
            set_error(err, err_len, "fixed cohort logits unavailable");
            return 1;
        }
        memcpy(engine->logits + (size_t) lane * engine->owner->vocab_size,
               logits, logits_bytes);
        engine->pos[lane]++;
    }
    return 0;
}

static int32_t rackllm_llama_batch_sample_factor(
        struct rackllm_llama_batch_engine * engine, int32_t slot,
        double temperature, int32_t domain_include, const int32_t * domain_ids,
        int32_t domain_count, int32_t constrain_to_domain,
        const int32_t * child_ids, const double * child_masses, int32_t child_count,
        double draw, int32_t * out_id, double * out_metrics) {
    if (!engine || slot < 0 || slot >= engine->capacity || !engine->active[slot]) return -2;
    size_t offset = (size_t) slot * engine->owner->vocab_size;
    return sample_factor_logits(
        engine->logits + offset, engine->owner->vocab_size,
        engine->factor_weights + offset, engine->child_factors + offset,
        engine->child_stamps + offset, engine->child_generation + slot,
        temperature, domain_include, domain_ids, domain_count,
        constrain_to_domain, child_ids, child_masses, child_count, draw,
        out_id, out_metrics);
}

#ifdef RACKLLM_ENABLE_CONFORMANCE
/* Diagnostic-only copy used by the fixed-profile conformance test. */
int32_t rackllm_llama_batch_copy_logits(
        struct rackllm_llama_batch_engine * engine,
        int32_t slot,
        float * out,
        int32_t count) {
    if (!engine || slot < 0 || slot >= engine->capacity || !engine->active[slot] ||
        !out || count != engine->owner->vocab_size) return 1;
    memcpy(out,
           engine->logits + (size_t) slot * engine->owner->vocab_size,
           (size_t) count * sizeof(float));
    return 0;
}
#endif

/* One FFI crossing for all ready lanes.  Parallelism is exclusively across
 * independent slots; rackllm_llama_batch_sample_factor retains ascending
 * token-id scans within each slot. */
int32_t rackllm_llama_batch_sample_factors(
        struct rackllm_llama_batch_engine * engine,
        const int32_t * slots, const double * temperatures,
        const int32_t * domain_includes, const int32_t * domain_offsets,
        const int32_t * domain_ids, const int32_t * constrain_to_domains,
        const int32_t * child_offsets, const int32_t * child_ids,
        const double * child_masses, const double * draws, int32_t count,
        int32_t * out_ids, double * out_metrics, int32_t * out_counts) {
    if (!engine || !slots || !temperatures || !domain_includes ||
        !domain_offsets || !constrain_to_domains || !child_offsets || !draws ||
        !out_ids || !out_metrics || !out_counts || count < 0 ||
        count > engine->capacity) return 1;
#ifdef _OPENMP
#pragma omp parallel for schedule(static) num_threads(engine->factor_threads)
#endif
    for (int32_t i = 0; i < count; i++) {
        int32_t domain_begin = domain_offsets[i];
        int32_t child_begin = child_offsets[i];
        out_counts[i] = rackllm_llama_batch_sample_factor(
            engine, slots[i], temperatures[i], domain_includes[i],
            domain_ids ? domain_ids + domain_begin : NULL,
            domain_offsets[i + 1] - domain_begin, constrain_to_domains[i],
            child_ids ? child_ids + child_begin : NULL,
            child_masses ? child_masses + child_begin : NULL,
            child_offsets[i + 1] - child_begin, draws[i], out_ids + i,
            out_metrics + 3 * i);
    }
    return 0;
}

int32_t rackllm_llama_batch_end(struct rackllm_llama_batch_engine * engine) {
    if (!engine) return 1;
    for (int32_t slot = 0; slot < engine->capacity; slot++) {
        if (!engine->active[slot]) return 1;
        engine->active[slot] = false;
    }
    return 0;
}

int32_t rackllm_llama_batch_reset(struct rackllm_llama_batch_engine * engine,
                                  const int32_t * slots,
                                  int32_t count,
                                  char * err,
                                  size_t err_len) {
    if (!engine || !slots || count < 0 || count > engine->capacity) {
        set_error(err, err_len, "invalid fixed-cohort reset request");
        return 1;
    }
    uint32_t seen = 0;
    for (int32_t i = 0; i < count; i++) {
        int32_t slot = slots[i];
        uint32_t bit = slot >= 0 && slot < 32 ? UINT32_C(1) << slot : 0;
        if (slot < 0 || slot >= engine->capacity || (seen & bit) != 0 ||
            batch_engine_restore_slot(engine, slot, err, err_len) != 0) {
            return 1;
        }
        seen |= bit;
    }
    return 0;
}
