#include <stdbool.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "llama.h"

struct rackllm_llama_model {
    struct llama_model * model;
    const struct llama_vocab * vocab;
    int32_t vocab_size;
    int32_t * eog_tokens;
    int32_t eog_count;
    int32_t context_size;
    int32_t threads;
};

struct rackllm_llama_session {
    struct rackllm_llama_model * owner;
    struct llama_context * ctx;
    int32_t pos;
};

static int backend_initialized = 0;

static void set_error(char * err, size_t err_len, const char * message) {
    if (err == NULL || err_len == 0) {
        return;
    }
    snprintf(err, err_len, "%s", message);
}

static void ensure_backend(void) {
    if (!backend_initialized) {
        llama_backend_init();
        backend_initialized = 1;
    }
}

struct rackllm_llama_model *
rackllm_llama_model_open(const char * path_model,
                         int32_t context_size,
                         int32_t threads,
                         int32_t gpu_layers,
                         char * err,
                         size_t err_len) {
    ensure_backend();
    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = gpu_layers;
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
    handle->context_size = context_size;
    handle->threads = threads;
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

static int decode_tokens(struct rackllm_llama_session * session,
                         const int32_t * tokens,
                         int32_t n_tokens,
                         char * err,
                         size_t err_len) {
    if (n_tokens <= 0) {
        set_error(err, err_len, "cannot decode an empty token batch");
        return 1;
    }
    if (session->pos + n_tokens > session->owner->context_size) {
        set_error(err, err_len, "token batch exceeds llama.cpp context size");
        return 1;
    }

    struct llama_batch batch = llama_batch_init(n_tokens, 0, 1);
    batch.n_tokens = n_tokens;
    for (int32_t i = 0; i < n_tokens; i++) {
        batch.token[i] = (llama_token) tokens[i];
        batch.pos[i] = session->pos + i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = (i == n_tokens - 1) ? 1 : 0;
    }

    int32_t status = llama_decode(session->ctx, batch);
    llama_batch_free(batch);
    if (status != 0) {
        snprintf(err, err_len, "llama_decode failed with status %d", status);
        return status;
    }
    session->pos += n_tokens;
    return 0;
}

struct rackllm_llama_session *
rackllm_llama_session_start(struct rackllm_llama_model * handle,
                            const int32_t * prompt,
                            int32_t n_prompt,
                            char * err,
                            size_t err_len) {
    llama_token bos_token = 0;
    if (n_prompt <= 0) {
        bos_token = llama_vocab_bos(handle->vocab);
        if (bos_token < 0) {
            set_error(err, err_len, "prompt token ids are empty and model has no BOS token");
            return NULL;
        }
        prompt = &bos_token;
        n_prompt = 1;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = (uint32_t) handle->context_size;
    cparams.n_batch = (uint32_t) handle->context_size;
    cparams.n_ubatch = (uint32_t) handle->context_size;
    cparams.n_threads = handle->threads;
    cparams.n_threads_batch = handle->threads;
    cparams.no_perf = true;

    struct llama_context * ctx = llama_init_from_model(handle->model, cparams);
    if (ctx == NULL) {
        set_error(err, err_len, "llama_init_from_model failed");
        return NULL;
    }

    struct rackllm_llama_session * session =
        (struct rackllm_llama_session *) calloc(1, sizeof(struct rackllm_llama_session));
    if (session == NULL) {
        llama_free(ctx);
        set_error(err, err_len, "calloc session failed");
        return NULL;
    }
    session->owner = handle;
    session->ctx = ctx;
    session->pos = 0;

    if (decode_tokens(session, prompt, n_prompt, err, err_len) != 0) {
        llama_free(ctx);
        free(session);
        return NULL;
    }
    return session;
}

int32_t rackllm_llama_session_reset(struct rackllm_llama_session * session,
                                    const int32_t * prompt,
                                    int32_t n_prompt,
                                    char * err,
                                    size_t err_len) {
    llama_token bos_token = 0;
    if (session == NULL || session->ctx == NULL) {
        set_error(err, err_len, "cannot reset a null session");
        return 1;
    }
    if (n_prompt <= 0) {
        bos_token = llama_vocab_bos(session->owner->vocab);
        if (bos_token < 0) {
            set_error(err, err_len, "prompt token ids are empty and model has no BOS token");
            return 1;
        }
        prompt = &bos_token;
        n_prompt = 1;
    }

    llama_memory_clear(llama_get_memory(session->ctx), false);
    session->pos = 0;
    return decode_tokens(session, prompt, n_prompt, err, err_len);
}

void rackllm_llama_session_close(struct rackllm_llama_session * session) {
    if (session == NULL) {
        return;
    }
    if (session->ctx != NULL) {
        llama_free(session->ctx);
    }
    free(session);
}

float * rackllm_llama_session_logits(struct rackllm_llama_session * session,
                                     char * err,
                                     size_t err_len) {
    float * logits = llama_get_logits_ith(session->ctx, -1);
    if (logits == NULL) {
        set_error(err, err_len, "llama_get_logits_ith returned null");
        return NULL;
    }
    return logits;
}

int32_t rackllm_llama_session_commit(struct rackllm_llama_session * session,
                                     int32_t token,
                                     char * err,
                                     size_t err_len) {
    return decode_tokens(session, &token, 1, err, err_len);
}

static bool sorted_contains(const int32_t * ids, int32_t count, int32_t id) {
    int32_t lo = 0, hi = count - 1;
    while (lo <= hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (ids[mid] == id) return true;
        if (ids[mid] < id) lo = mid + 1; else hi = mid - 1;
    }
    return false;
}

static double child_mass(const int32_t * ids, const double * masses,
                         int32_t count, int32_t id) {
    int32_t lo = 0, hi = count - 1;
    while (lo <= hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (ids[mid] == id) return masses[mid];
        if (ids[mid] < id) lo = mid + 1; else hi = mid - 1;
    }
    return 1.0;
}

static bool in_domain(bool include, const int32_t * ids, int32_t count, int32_t id) {
    return include == sorted_contains(ids, count, id);
}

/* Exact categorical draw for exp(logit / temperature) times the CARS factor.
 * out_metrics = base log-probability, base probability, frontier mass. */
int32_t rackllm_llama_session_sample_factor(
        struct rackllm_llama_session * session,
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
    if (session == NULL || temperature <= 0.0 || out_id == NULL || out_metrics == NULL) return -2;
    const float * logits = llama_get_logits_ith(session->ctx, -1);
    if (logits == NULL) return -2;
    const int32_t vocab = session->owner->vocab_size;
    double max_base = -INFINITY, max_adjusted = -INFINITY;
    int32_t candidates = 0;

    for (int32_t id = 0; id < vocab; id++) {
        double base = (double) logits[id] / temperature;
        if (!isfinite(base)) continue;
        if (base > max_base) max_base = base;
        bool frontier = in_domain(domain_include != 0, domain_ids, domain_count, id);
        double mass = (constrain_to_domain && !frontier)
            ? 0.0 : child_mass(child_ids, child_masses, child_count, id);
        if (mass > 0.0) {
            double adjusted = base + log(mass);
            if (adjusted > max_adjusted) max_adjusted = adjusted;
            candidates++;
        }
    }
    if (candidates == 0 || !isfinite(max_base) || !isfinite(max_adjusted)) return -1;

    double base_sum = 0.0, frontier_sum = 0.0, adjusted_sum = 0.0;
    for (int32_t id = 0; id < vocab; id++) {
        double base = (double) logits[id] / temperature;
        if (!isfinite(base)) continue;
        double base_weight = exp(base - max_base);
        base_sum += base_weight;
        bool frontier = in_domain(domain_include != 0, domain_ids, domain_count, id);
        if (frontier) frontier_sum += base_weight;
        double mass = (constrain_to_domain && !frontier)
            ? 0.0 : child_mass(child_ids, child_masses, child_count, id);
        if (mass > 0.0) adjusted_sum += exp(base + log(mass) - max_adjusted);
    }

    double target = fmin(fmax(draw, 0.0), 0.9999999999999999) * adjusted_sum;
    double cumulative = 0.0;
    int32_t selected = -1;
    double selected_base = -INFINITY;
    for (int32_t id = 0; id < vocab; id++) {
        double base = (double) logits[id] / temperature;
        if (!isfinite(base)) continue;
        bool frontier = in_domain(domain_include != 0, domain_ids, domain_count, id);
        double mass = (constrain_to_domain && !frontier)
            ? 0.0 : child_mass(child_ids, child_masses, child_count, id);
        if (mass <= 0.0) continue;
        selected = id;
        selected_base = base;
        cumulative += exp(base + log(mass) - max_adjusted);
        if (cumulative > target) break;
    }
    if (selected < 0) return -1;
    double log_z = max_base + log(base_sum);
    out_id[0] = selected;
    out_metrics[0] = selected_base - log_z;
    out_metrics[1] = exp(out_metrics[0]);
    out_metrics[2] = frontier_sum / base_sum;
    return candidates;
}
