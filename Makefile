RACO ?= raco
RACKET ?= racket
RACK_LLM_GGUF_MODEL ?=
LLAMA_CPP_DIR ?=
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build-rack-llm
LLAMA_CPP_INCLUDE_DIR ?= $(LLAMA_CPP_DIR)/include
LLAMA_CPP_LIB_DIR ?= $(LLAMA_CPP_BUILD_DIR)/bin
LLAMA_CPP_CFLAGS ?= -I$(LLAMA_CPP_DIR)/ggml/include

LOCAL_COLLECTIONS := PLTCOLLECTS="$(abspath ..):"

.PHONY: help install lint compile ci cold-ci unit-ci test native native-llama native-regex \
	native-conformance fixed-cohort-model-matrix experiments-ci clean distclean check-no-orphan-bytecode

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Build PCRE2 support and install the Racket package.' \
	  '  make compile       Compile the library and tests.' \
	  '  make clean         Remove generated build and language caches.' \
	  '  make distclean     Also remove experiment environments, cache, and artifacts.' \
	  '  make native-llama  Build the llama.cpp shim (requires LLAMA_CPP_DIR).' \
	  '  make fixed-cohort-model-matrix  Run bitwise replay tests on configured GGUF models.' \
	  '  make lint          Build native regex support and compile the library.' \
	  '  make test          Run all tests (requires LLAMA_CPP_DIR and RACK_LLM_GGUF_MODEL).' \
	  '  make experiments-ci Run the paper experiment static CI checks.' \
	  '  make ci            Run lint and tests.'

install: native-regex
	$(RACO) pkg install --auto

compile:
	$(RACO) make main.rkt backend.rkt model-llama-cpp.rkt tests/support/fake-cohort.rkt tests/loc-test.rkt tests/contract-test.rkt tests/e2e-real-test.rkt tests/e2e-sampler-test.rkt tests/private/regex-test.rkt tests/private/sampling-test.rkt tests/private/cars-test.rkt tests/private/guidance-test.rkt tests/private/weak-test.rkt tests/private/runtime-test.rkt tests/private/logits-test.rkt tests/private/llama-cpp-test.rkt
	$(LOCAL_COLLECTIONS) $(RACO) make experiments/racket/rack_runner.rkt experiments/racket/synthetic_exactness.rkt experiments/racket/validate_hard.rkt

check-no-orphan-bytecode:
	@failed=0; \
	for file in $$(find . -type f -path '*/compiled/*_rkt.zo'); do \
	  root=$${file%%/compiled/*}; name=$$(basename "$$file" _rkt.zo); \
	  if test ! -f "$$root/$$name.rkt"; then echo "orphan bytecode: $$file" >&2; failed=1; fi; \
	done; \
	test $$failed -eq 0

native-llama:
	@test -n "$(LLAMA_CPP_DIR)" || { \
	  echo 'LLAMA_CPP_DIR must point to a llama.cpp checkout.' >&2; \
	  exit 2; \
	}
	$(MAKE) -C native/llama \
	  LLAMA_CPP_INCLUDE_DIR="$(LLAMA_CPP_INCLUDE_DIR)" \
	  LLAMA_CPP_LIB_DIR="$(LLAMA_CPP_LIB_DIR)" \
	  LLAMA_CPP_CFLAGS="$(LLAMA_CPP_CFLAGS)"

native-conformance: native-llama
	$(MAKE) -C native/llama conformance \
	  LLAMA_CPP_INCLUDE_DIR="$(LLAMA_CPP_INCLUDE_DIR)" \
	  LLAMA_CPP_LIB_DIR="$(LLAMA_CPP_LIB_DIR)" \
	  LLAMA_CPP_CFLAGS="$(LLAMA_CPP_CFLAGS)"

fixed-cohort-model-matrix: native-conformance
	@test -n "$(RACK_LLM_PHI_MODEL)" || { echo 'RACK_LLM_PHI_MODEL is required' >&2; exit 2; }
	@test -n "$(RACK_LLM_QWEN35_MODEL)" || { echo 'RACK_LLM_QWEN35_MODEL is required' >&2; exit 2; }
	native/llama/build/fixed-cohort-replay "$(RACK_LLM_PHI_MODEL)" 8 0 20 768 0
	native/llama/build/fixed-cohort-replay "$(RACK_LLM_PHI_MODEL)" 8 999 50 768 0
	native/llama/build/fixed-cohort-replay "$(RACK_LLM_QWEN35_MODEL)" 8 0 20 768 0
	native/llama/build/fixed-cohort-replay "$(RACK_LLM_QWEN35_MODEL)" 8 999 50 768 0

native-regex:
	$(MAKE) -C native/regex

native: native-llama native-regex

lint: native-regex compile

ci: native lint test

cold-ci: clean unit-ci

unit-ci: native-regex compile check-no-orphan-bytecode
	$(RACO) test tests/private tests/loc-test.rkt tests/contract-test.rkt tests/e2e-sampler-test.rkt

test: native
	@test -n "$(RACK_LLM_GGUF_MODEL)" || { \
	  echo 'RACK_LLM_GGUF_MODEL must point to a GGUF model.' >&2; \
	  exit 2; \
	}
	RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(LOCAL_COLLECTIONS) $(RACO) test tests

experiments-ci:
	$(MAKE) -C experiments test

clean:
	find . \( -path ./experiments/.venv -o -path ./experiments/.cache \) -prune -o \
	  -type d \( -name compiled -o -name __pycache__ -o -name .pytest_cache \) \
	  -prune -exec rm -rf {} +
	rm -rf .tmp
	$(MAKE) -C native/llama clean
	$(MAKE) -C native/regex clean

distclean: clean
	rm -rf experiments/.venv experiments/.cache experiments/artifacts
