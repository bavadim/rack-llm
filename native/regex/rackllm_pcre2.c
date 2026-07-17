#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rackllm_pcre2.h"
#ifdef _OPENMP
#include <omp.h>
#endif

#define INITIAL_WORKSPACE_SIZE 128

struct rackllm_vocab {
    char *bytes;
    size_t *offsets;
    int32_t size;
    size_t max_token_length;
};

typedef struct allowed_cache_entry {
    int *workspace;
    size_t workspace_size;
    int restartable;
    int started;
    int32_t *allowed;
    int32_t allowed_count;
    struct allowed_cache_entry *next;
} allowed_cache_entry;

struct rackllm_regex {
    pcre2_code *code;
    rackllm_vocab *vocab;
    int restart_safe;
    allowed_cache_entry *allowed_cache;
    int allowed_cache_count;
};

struct rackllm_regex_state {
    rackllm_regex *regex;
    char *prefix;
    size_t length;
    int accepting;
    int32_t *allowed;
    int32_t allowed_count;
    int *workspace;
    size_t workspace_size;
    int restartable;
    int started;
};

static void set_error(char *err, size_t n, const char *message) {
    if (err && n) snprintf(err, n, "%s", message);
}

static const char *token_bytes(const rackllm_vocab *vocab, int32_t id) {
    return vocab->bytes + vocab->offsets[id];
}

static size_t token_length(const rackllm_vocab *vocab, int32_t id) {
    return vocab->offsets[id + 1] - vocab->offsets[id];
}

rackllm_vocab *rackllm_vocab_open(const char *bytes,
                                  size_t byte_count,
                                  const int32_t *lengths,
                                  int32_t vocab_size,
                                  char *err,
                                  size_t err_len) {
    if (vocab_size < 0 || (byte_count && !bytes) || (vocab_size && !lengths)) {
        set_error(err, err_len, "invalid vocabulary input");
        return NULL;
    }
    if ((size_t) vocab_size > (SIZE_MAX / sizeof(size_t)) - 1) {
        set_error(err, err_len, "vocabulary offsets overflow");
        return NULL;
    }

    rackllm_vocab *vocab = calloc(1, sizeof(*vocab));
    if (!vocab) {
        set_error(err, err_len, "vocabulary allocation failed");
        return NULL;
    }
    vocab->size = vocab_size;
    vocab->offsets = malloc(((size_t) vocab_size + 1) * sizeof(size_t));
    vocab->bytes = malloc(byte_count ? byte_count : 1);
    if (!vocab->offsets || !vocab->bytes) {
        set_error(err, err_len, "vocabulary storage allocation failed");
        free(vocab->offsets);
        free(vocab->bytes);
        free(vocab);
        return NULL;
    }

    size_t offset = 0;
    vocab->offsets[0] = 0;
    for (int32_t id = 0; id < vocab_size; id++) {
        if (lengths[id] < 0 || (size_t) lengths[id] > byte_count - offset) {
            set_error(err, err_len, "invalid vocabulary token lengths");
            free(vocab->offsets);
            free(vocab->bytes);
            free(vocab);
            return NULL;
        }
        offset += (size_t) lengths[id];
        if ((size_t) lengths[id] > vocab->max_token_length) {
            vocab->max_token_length = (size_t) lengths[id];
        }
        vocab->offsets[id + 1] = offset;
    }
    if (offset != byte_count) {
        set_error(err, err_len, "vocabulary lengths do not match byte count");
        free(vocab->offsets);
        free(vocab->bytes);
        free(vocab);
        return NULL;
    }
    if (byte_count) memcpy(vocab->bytes, bytes, byte_count);
    return vocab;
}

void rackllm_vocab_close(rackllm_vocab *vocab) {
    if (!vocab) return;
    free(vocab->bytes);
    free(vocab->offsets);
    free(vocab);
}

/* 2 = accepting, 1 = live partial, 0 = dead, -1 = backend failure. */
static int live(rackllm_regex *regex, const char *text, size_t length) {
    pcre2_match_data *data = pcre2_match_data_create_from_pattern(regex->code, NULL);
    if (!data) return -1;
    int rc = pcre2_match(regex->code, (PCRE2_SPTR) text, length, 0,
                         PCRE2_PARTIAL_HARD, data, NULL);
    pcre2_match_data_free(data);
    if (rc >= 0) return 2;
    if (rc == PCRE2_ERROR_PARTIAL) return 1;
    if (rc == PCRE2_ERROR_NOMATCH) return 0;
    return -1;
}

static int grow_workspace(int **workspace, size_t *size) {
    size_t next = *size ? *size * 2 : INITIAL_WORKSPACE_SIZE;
    if (next < *size || next > SIZE_MAX / sizeof(int)) return 0;
    int *grown = realloc(*workspace, next * sizeof(int));
    if (!grown) return 0;
    if (next > *size) memset(grown + *size, 0, (next - *size) * sizeof(int));
    *workspace = grown;
    *size = next;
    return 1;
}

static int restart_match(rackllm_regex *regex,
                         const rackllm_regex_state *parent,
                         const char *text,
                         size_t length,
                         pcre2_match_data *data,
                         int **workspace,
                         size_t *workspace_size) {
    if (!*workspace) {
        if (!*workspace_size) *workspace_size = INITIAL_WORKSPACE_SIZE;
        if (*workspace_size > SIZE_MAX / sizeof(int)) return PCRE2_ERROR_NOMEMORY;
        *workspace = calloc(*workspace_size, sizeof(int));
        if (!*workspace) return PCRE2_ERROR_NOMEMORY;
    }
    for (;;) {
        if (parent && parent->started) {
            if (*workspace_size < parent->workspace_size) {
                while (*workspace_size < parent->workspace_size) {
                    if (!grow_workspace(workspace, workspace_size)) return PCRE2_ERROR_NOMEMORY;
                }
            }
            memcpy(*workspace, parent->workspace,
                   parent->workspace_size * sizeof(int));
            if (*workspace_size > parent->workspace_size) {
                memset(*workspace + parent->workspace_size, 0,
                       (*workspace_size - parent->workspace_size) * sizeof(int));
            }
        } else {
            memset(*workspace, 0, *workspace_size * sizeof(int));
        }
        uint32_t options = PCRE2_PARTIAL_HARD;
        if (parent && parent->started) options |= PCRE2_DFA_RESTART;
        int rc = pcre2_dfa_match(regex->code, (PCRE2_SPTR) text, length, 0,
                                 options, data, NULL, *workspace, *workspace_size);
        if (rc != PCRE2_ERROR_DFA_WSSIZE) return rc;
        if (!grow_workspace(workspace, workspace_size)) return PCRE2_ERROR_NOMEMORY;
    }
}

static int accepting(rackllm_regex *regex, const char *text, size_t length) {
    pcre2_match_data *data = pcre2_match_data_create_from_pattern(regex->code, NULL);
    if (!data) return 0;
    int rc = pcre2_match(regex->code, (PCRE2_SPTR) text, length, 0,
                         0, data, NULL);
    pcre2_match_data_free(data);
    return rc >= 0;
}

rackllm_regex *rackllm_regex_open(const char *pattern,
                                  rackllm_vocab *vocab,
                                  int restart_safe,
                                  char *err,
                                  size_t err_len) {
    if (!vocab) {
        set_error(err, err_len, "null vocabulary");
        return NULL;
    }
    int error_code;
    PCRE2_SIZE error_offset;
    pcre2_code *code = pcre2_compile((PCRE2_SPTR) pattern, PCRE2_ZERO_TERMINATED,
                                     PCRE2_UTF | PCRE2_ALT_BSUX,
                                     &error_code, &error_offset, NULL);
    if (!code) {
        PCRE2_UCHAR message[256];
        pcre2_get_error_message(error_code, message, sizeof(message));
        if (err && err_len) snprintf(err, err_len, "regex error at offset %zu: %s", error_offset, message);
        return NULL;
    }
    rackllm_regex *regex = calloc(1, sizeof(*regex));
    if (!regex) {
        pcre2_code_free(code);
        set_error(err, err_len, "regex allocation failed");
        return NULL;
    }
    regex->code = code;
    regex->vocab = vocab;
    regex->restart_safe = restart_safe != 0;
    return regex;
}

void rackllm_regex_close(rackllm_regex *regex) {
    if (!regex) return;
    allowed_cache_entry *entry = regex->allowed_cache;
    while (entry) {
        allowed_cache_entry *next = entry->next;
        free(entry->workspace);
        free(entry->allowed);
        free(entry);
        entry = next;
    }
    pcre2_code_free(regex->code);
    free(regex);
}

rackllm_regex_state *rackllm_regex_start(rackllm_regex *regex) {
    if (!regex) return NULL;
    rackllm_regex_state *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->prefix = calloc(1, 1);
    if (!state->prefix) {
        free(state);
        return NULL;
    }
    state->regex = regex;
    state->accepting = accepting(regex, "", 0);
    state->allowed_count = -1;
    return state;
}

void rackllm_regex_state_close(rackllm_regex_state *state) {
    if (!state) return;
    free(state->prefix);
    free(state->workspace);
    free(state->allowed);
    free(state);
}

static int compute_allowed(rackllm_regex_state *state) {
    if (state->allowed_count >= 0) return 1;
    rackllm_vocab *vocab = state->regex->vocab;
    if (state->regex->restart_safe) {
        for (allowed_cache_entry *entry = state->regex->allowed_cache;
             entry; entry = entry->next) {
            if (entry->started == state->started &&
                entry->restartable == state->restartable &&
                entry->workspace_size == state->workspace_size &&
                (entry->workspace_size == 0 ||
                 memcmp(entry->workspace, state->workspace,
                        entry->workspace_size * sizeof(int)) == 0)) {
                state->allowed = malloc(
                    (size_t) entry->allowed_count * sizeof(int32_t));
                if (entry->allowed_count && !state->allowed) return 0;
                if (entry->allowed_count) {
                    memcpy(state->allowed, entry->allowed,
                           (size_t) entry->allowed_count * sizeof(int32_t));
                }
                state->allowed_count = entry->allowed_count;
                return 1;
            }
        }
    }
    state->allowed = malloc((size_t) vocab->size * sizeof(int32_t));
    uint8_t *allowed = calloc((size_t) vocab->size, sizeof(uint8_t));
    if (vocab->size && (!state->allowed || !allowed)) {
        free(state->allowed);
        free(allowed);
        state->allowed = NULL;
        return 0;
    }
    size_t capacity = state->length + vocab->max_token_length + 1;
    int failed = 0;
#pragma omp parallel reduction(|:failed)
    {
        pcre2_match_data *data = pcre2_match_data_create(8, NULL);
        char *subject = state->regex->restart_safe ? NULL : malloc(capacity);
        int *workspace = NULL;
        size_t workspace_size = state->workspace_size;
        if (!data || (!state->regex->restart_safe && !subject)) {
            failed = 1;
        }
        if (subject) memcpy(subject, state->prefix, state->length);
#pragma omp for schedule(static)
        for (int32_t id = 0; id < vocab->size; id++) {
            if (data && (state->regex->restart_safe || subject)) {
                size_t length = token_length(vocab, id);
                if (!length) continue;
                int rc;
                if (state->regex->restart_safe) {
                    if (state->started && !state->restartable) continue;
                    rc = restart_match(state->regex, state,
                                       token_bytes(vocab, id), length, data,
                                       &workspace, &workspace_size);
                } else {
                    size_t n = state->length + length;
                    memcpy(subject + state->length, token_bytes(vocab, id), length);
                    subject[n] = 0;
                    rc = pcre2_match(state->regex->code, (PCRE2_SPTR) subject, n, 0,
                                     PCRE2_PARTIAL_HARD, data, NULL);
                }
                int status = rc >= 0 || rc == PCRE2_ERROR_PARTIAL
                           ? 1
                           : rc == PCRE2_ERROR_NOMATCH ? 0 : -1;
                if (status < 0) failed = 1;
                else if (status) allowed[id] = 1;
            }
        }
        free(subject);
        free(workspace);
        pcre2_match_data_free(data);
    }
    if (failed) {
        free(allowed);
        free(state->allowed);
        state->allowed = NULL;
        state->allowed_count = -1;
        return 0;
    }
    state->allowed_count = 0;
    for (int32_t id = 0; id < vocab->size; id++) {
        if (allowed[id]) state->allowed[state->allowed_count++] = id;
    }
    free(allowed);
    if (state->regex->restart_safe) {
        allowed_cache_entry *entry = calloc(1, sizeof(*entry));
        if (entry) {
            if (state->workspace_size) {
                entry->workspace = malloc(state->workspace_size * sizeof(int));
            }
            if (state->allowed_count) {
                entry->allowed = malloc(
                    (size_t) state->allowed_count * sizeof(int32_t));
            }
            if ((!state->workspace_size || entry->workspace) &&
                (!state->allowed_count || entry->allowed)) {
                if (state->workspace_size) {
                    memcpy(entry->workspace, state->workspace,
                           state->workspace_size * sizeof(int));
                }
                if (state->allowed_count) {
                    memcpy(entry->allowed, state->allowed,
                           (size_t) state->allowed_count * sizeof(int32_t));
                }
                entry->workspace_size = state->workspace_size;
                entry->restartable = state->restartable;
                entry->started = state->started;
                entry->allowed_count = state->allowed_count;
                entry->next = state->regex->allowed_cache;
                state->regex->allowed_cache = entry;
                state->regex->allowed_cache_count++;
                if (state->regex->allowed_cache_count > 8) {
                    allowed_cache_entry *previous = NULL;
                    allowed_cache_entry *tail = state->regex->allowed_cache;
                    while (tail->next) {
                        previous = tail;
                        tail = tail->next;
                    }
                    if (previous) previous->next = NULL;
                    free(tail->workspace);
                    free(tail->allowed);
                    free(tail);
                    state->regex->allowed_cache_count--;
                }
            } else {
                free(entry->workspace);
                free(entry->allowed);
                free(entry);
            }
        }
    }
    return 1;
}

int32_t rackllm_regex_allowed_count(rackllm_regex_state *state) {
    return state && compute_allowed(state) ? state->allowed_count : -1;
}

int32_t rackllm_regex_allowed_copy(rackllm_regex_state *state,
                                   int32_t *out,
                                   int32_t capacity) {
    if (!state || !compute_allowed(state) || capacity < state->allowed_count
        || (state->allowed_count && !out)) return -1;
    if (state->allowed_count) {
        memcpy(out, state->allowed,
               (size_t) state->allowed_count * sizeof(int32_t));
    }
    return state->allowed_count;
}

int rackllm_regex_step(rackllm_regex_state *state,
                       int32_t token_id,
                       rackllm_regex_state **out) {
    if (out) *out = NULL;
    if (!state || !out) return -1;
    rackllm_vocab *vocab = state->regex->vocab;
    if (token_id < 0 || token_id >= vocab->size) return 0;
    size_t length = token_length(vocab, token_id);
    if (length > SIZE_MAX - state->length - 1) return -1;
    size_t n = state->length + length;
    char *subject = malloc(n + 1);
    if (!subject) return -1;
    memcpy(subject, state->prefix, state->length);
    memcpy(subject + state->length, token_bytes(vocab, token_id), length);
    subject[n] = 0;
    int status;
    int incremental_rc = PCRE2_ERROR_NOMATCH;
    int *workspace = NULL;
    size_t workspace_size = state->workspace_size;
    if (state->regex->restart_safe) {
        if (state->started && !state->restartable) {
            free(subject);
            return 0;
        }
        pcre2_match_data *data = pcre2_match_data_create(8, NULL);
        if (!data) {
            free(subject);
            return -1;
        }
        incremental_rc = restart_match(state->regex, state,
                                       token_bytes(vocab, token_id), length, data,
                                       &workspace, &workspace_size);
        pcre2_match_data_free(data);
        status = incremental_rc >= 0 ? 2
               : incremental_rc == PCRE2_ERROR_PARTIAL ? 1
               : incremental_rc == PCRE2_ERROR_NOMATCH ? 0 : -1;
    } else {
        status = live(state->regex, subject, n);
    }
    if (status <= 0) {
        free(workspace);
        free(subject);
        return status;
    }
    rackllm_regex_state *next = calloc(1, sizeof(*next));
    if (!next) {
        free(workspace);
        free(subject);
        return -1;
    }
    next->regex = state->regex;
    next->prefix = subject;
    next->length = n;
    /* PCRE2_PARTIAL_HARD may report PARTIAL even when a complete match also
     * exists, so acceptance cannot be inferred from the liveness call. */
    next->accepting = accepting(state->regex, subject, n);
    next->allowed_count = -1;
    if (state->regex->restart_safe) {
        next->workspace = workspace;
        next->workspace_size = workspace_size;
        next->restartable = incremental_rc == PCRE2_ERROR_PARTIAL;
        next->started = 1;
    } else {
        free(workspace);
    }
    *out = next;
    return 1;
}

int rackllm_regex_accepting(rackllm_regex_state *state) {
    return state ? state->accepting : 0;
}

int rackllm_regex_abi_version(void) {
    return RACKLLM_REGEX_ABI_VERSION;
}

int rackllm_regex_match_compiled(rackllm_regex *regex, const char *text) {
    if (!regex || !text) return -1;
    pcre2_match_data *data = pcre2_match_data_create_from_pattern(regex->code, NULL);
    if (!data) return -1;
    int rc = pcre2_match(regex->code, (PCRE2_SPTR) text, strlen(text), 0, 0, data, NULL);
    pcre2_match_data_free(data);
    return rc >= 0;
}
