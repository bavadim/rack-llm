RACO ?= raco
RACK_LLM_GGUF_MODEL ?= /mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf
LLAMA_CPP_DIR ?= /mnt/storage/work/llama.cpp
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build-rack-llm
LLAMA_CPP_INCLUDE_DIR ?= $(LLAMA_CPP_DIR)/include
LLAMA_CPP_LIB_DIR ?= $(LLAMA_CPP_BUILD_DIR)/bin
LLAMA_CPP_CFLAGS ?= -I$(LLAMA_CPP_DIR)/ggml/include

.PHONY: help install lint compile arch-lint dep-lint ci test native-llama

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Install the Racket package with raco.' \
	  '  make compile       Compile the library and tests.' \
	  '  make native-llama  Build the optional in-process llama.cpp provider shim.' \
	  '  make arch-lint     Report module size/surface and check architecture rules.' \
	  '  make dep-lint      Check architecture and actionable unused requires.' \
	  '  make lint          Run compile and dependency lint.' \
	  '  make test          Run contract and real native Qwen GGUF e2e tests.' \
	  '  make ci            Run lint and tests.'

install:
	$(RACO) pkg install --auto

compile:
	$(RACO) make main.rkt model-llama-cpp.rkt tests/contract-test.rkt tests/e2e-real-test.rkt tests/e2e-sampler-test.rkt tests/private/sampling-test.rkt tests/private/runtime-test.rkt tests/private/logits-test.rkt tests/private/llama-cpp-test.rkt

native-llama:
	$(MAKE) -C native/llama \
	  LLAMA_CPP_INCLUDE_DIR="$(LLAMA_CPP_INCLUDE_DIR)" \
	  LLAMA_CPP_LIB_DIR="$(LLAMA_CPP_LIB_DIR)" \
	  LLAMA_CPP_CFLAGS="$(LLAMA_CPP_CFLAGS)"

arch-lint:
	RACO="$(RACO)" racket tools/arch-lint.rkt

dep-lint: arch-lint

lint: compile dep-lint

ci: native-llama lint test

test: native-llama
	RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(RACO) test tests
