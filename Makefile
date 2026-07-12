RACO ?= raco
RACK_LLM_GGUF_MODEL ?= /mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf
LLAMA_CPP_DIR ?= /mnt/storage/work/llama.cpp
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build-rack-llm
LLAMA_CPP_INCLUDE_DIR ?= $(LLAMA_CPP_DIR)/include
LLAMA_CPP_LIB_DIR ?= $(LLAMA_CPP_BUILD_DIR)/bin
LLAMA_CPP_CFLAGS ?= -I$(LLAMA_CPP_DIR)/ggml/include

.PHONY: help install lint compile ci test native native-llama native-regex experiments-ci

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Install the Racket package with raco.' \
	  '  make compile       Compile the library and tests.' \
	  '  make native-llama  Build the optional in-process llama.cpp provider shim.' \
	  '  make lint          Build native regex support and compile the library.' \
	  '  make test          Run contract and real native Qwen GGUF e2e tests.' \
	  '  make experiments-ci Run Experiment 012 local CI checks.' \
	  '  make ci            Run lint and tests.'

install:
	$(RACO) pkg install --auto

compile:
	$(RACO) make main.rkt model-llama-cpp.rkt tests/contract-test.rkt tests/e2e-real-test.rkt tests/e2e-sampler-test.rkt tests/private/regex-test.rkt tests/private/sampling-test.rkt tests/private/cars-test.rkt tests/private/guidance-test.rkt tests/private/weak-test.rkt tests/private/runtime-test.rkt tests/private/logits-test.rkt tests/private/llama-cpp-test.rkt

native-llama:
	$(MAKE) -C native/llama \
	  LLAMA_CPP_INCLUDE_DIR="$(LLAMA_CPP_INCLUDE_DIR)" \
	  LLAMA_CPP_LIB_DIR="$(LLAMA_CPP_LIB_DIR)" \
	  LLAMA_CPP_CFLAGS="$(LLAMA_CPP_CFLAGS)"

native-regex:
	$(MAKE) -C native/regex

native: native-llama native-regex

lint: native-regex compile

ci: native lint test

test: native
	RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(RACO) test tests

experiments-ci:
	$(MAKE) -C experiments/012_real_model_benchmark ci
