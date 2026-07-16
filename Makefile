RACO ?= raco
RACKET ?= racket
RACK_LLM_GGUF_MODEL ?=
LLAMA_CPP_DIR ?=
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build-rack-llm
LLAMA_CPP_INCLUDE_DIR ?= $(LLAMA_CPP_DIR)/include
LLAMA_CPP_LIB_DIR ?= $(LLAMA_CPP_BUILD_DIR)/bin
LLAMA_CPP_CFLAGS ?= -I$(LLAMA_CPP_DIR)/ggml/include

EXAMPLES := examples/hard-choice.rkt examples/hard-ban-batch.rkt examples/soft-pwsg.rkt
LOCAL_COLLECTIONS := PLTCOLLECTS="$(abspath ..):"

.PHONY: help install lint compile ci unit-ci test native native-llama native-regex \
	examples examples-check experiments-ci

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Build PCRE2 support and install the Racket package.' \
	  '  make compile       Compile the library and tests.' \
	  '  make native-llama  Build the llama.cpp shim (requires LLAMA_CPP_DIR).' \
	  '  make examples-check Compile and test examples with a mock model.' \
	  '  make examples      Run examples (requires LLAMA_CPP_DIR and RACK_LLM_GGUF_MODEL).' \
	  '  make lint          Build native regex support and compile the library.' \
	  '  make test          Run all tests (requires LLAMA_CPP_DIR and RACK_LLM_GGUF_MODEL).' \
	  '  make experiments-ci Run Experiment 012 local CI checks.' \
	  '  make ci            Run lint and tests.'

install: native-regex
	$(RACO) pkg install --auto

compile:
	$(RACO) make main.rkt model-llama-cpp.rkt tests/contract-test.rkt tests/e2e-real-test.rkt tests/e2e-sampler-test.rkt tests/private/regex-test.rkt tests/private/sampling-test.rkt tests/private/cars-test.rkt tests/private/guidance-test.rkt tests/private/weak-test.rkt tests/private/runtime-test.rkt tests/private/logits-test.rkt tests/private/llama-cpp-test.rkt

native-llama:
	@test -n "$(LLAMA_CPP_DIR)" || { \
	  echo 'LLAMA_CPP_DIR must point to a llama.cpp checkout.' >&2; \
	  exit 2; \
	}
	$(MAKE) -C native/llama \
	  LLAMA_CPP_INCLUDE_DIR="$(LLAMA_CPP_INCLUDE_DIR)" \
	  LLAMA_CPP_LIB_DIR="$(LLAMA_CPP_LIB_DIR)" \
	  LLAMA_CPP_CFLAGS="$(LLAMA_CPP_CFLAGS)"

native-regex:
	$(MAKE) -C native/regex

native: native-llama native-regex

lint: native-regex compile

ci: native lint test

examples-check: native-regex
	$(LOCAL_COLLECTIONS) $(RACO) make $(EXAMPLES) tests/examples-test.rkt
	$(LOCAL_COLLECTIONS) $(RACO) test tests/examples-test.rkt

unit-ci: native-regex compile examples-check
	$(RACO) test tests/private tests/contract-test.rkt tests/e2e-sampler-test.rkt

examples: native
	@test -n "$(RACK_LLM_GGUF_MODEL)" || { \
	  echo 'RACK_LLM_GGUF_MODEL must point to a GGUF model.' >&2; \
	  exit 2; \
	}
	@for example in $(EXAMPLES); do \
	  echo "Running $$example"; \
	  RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(LOCAL_COLLECTIONS) $(RACKET) "$$example" || exit $$?; \
	done

test: native
	@test -n "$(RACK_LLM_GGUF_MODEL)" || { \
	  echo 'RACK_LLM_GGUF_MODEL must point to a GGUF model.' >&2; \
	  exit 2; \
	}
	RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(LOCAL_COLLECTIONS) $(RACO) test tests

experiments-ci:
	$(MAKE) -C experiments/012_real_model_benchmark ci
