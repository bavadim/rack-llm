#ifndef RACKLLM_PCRE2_H
#define RACKLLM_PCRE2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RACKLLM_REGEX_ABI_VERSION 2

typedef struct rackllm_vocab rackllm_vocab;
typedef struct rackllm_regex rackllm_regex;
typedef struct rackllm_regex_state rackllm_regex_state;

int rackllm_regex_abi_version(void);
rackllm_vocab *rackllm_vocab_open(
    const char *, size_t, const int32_t *, int32_t, char *, size_t);
void rackllm_vocab_close(rackllm_vocab *);
rackllm_regex *rackllm_regex_open(
    const char *, rackllm_vocab *, int, char *, size_t);
void rackllm_regex_close(rackllm_regex *);
rackllm_regex_state *rackllm_regex_start(rackllm_regex *);
void rackllm_regex_state_close(rackllm_regex_state *);
int32_t rackllm_regex_allowed_count(rackllm_regex_state *);
int32_t rackllm_regex_allowed_copy(rackllm_regex_state *, int32_t *, int32_t);
int rackllm_regex_step(rackllm_regex_state *, int32_t, rackllm_regex_state **);
int rackllm_regex_accepting(rackllm_regex_state *);
int rackllm_regex_match_compiled(rackllm_regex *regex, const char *text);

#ifdef __cplusplus
}
#endif

#endif
