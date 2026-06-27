RACO ?= raco
LLAMA_CPP_DIR ?= .deps/llama.cpp
LLAMA_CPP_REF ?= master
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build
LLAMA_SERVER ?= $(LLAMA_CPP_BUILD_DIR)/bin/llama-server
RACK_LLM_MODEL ?= models/qwen2.5-0.5b-instruct-q4_k_m.gguf
RACK_LLM_LLAMA_SERVER ?= http://127.0.0.1:8080
RACK_LLM_TEST_PORT ?= 18080

WATCH_TARGET ?= test

.PHONY: help install env watch-deps deps model server lint ci test test-integration test-all test-readme test-examples test-weak-ifbench-fixture test-llama-local test-synthetic-small paper-small paper-full test-paper-full-missing test-acceptance test-acceptance-local watch clean-deps

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install                 Install the Racket package with raco.' \
	  '  make env                     Install watcher tooling, build llama.cpp, and download the model.' \
	  '  make deps                    Clone and build llama.cpp with LLGuidance support.' \
	  '  make model                   Download the default small GGUF model.' \
	  '  make server                  Run llama-server in the foreground.' \
	  '  make lint                    Run compile, require, dependency, and architecture checks.' \
	  '  make ci                      Run lint plus all non-environment-gated tests.' \
	  '  make test                    Run unit tests through raco.' \
	  '  make test-integration        Run local integration tests without network or models.' \
	  '  make test-all                Run all tests through raco; acceptance skips unless enabled.' \
	  '  make test-readme             Extract and run the README minimal pipeline.' \
	  '  make test-examples           Run runnable examples.' \
	  '  make test-weak-ifbench-fixture Run Weak-IFBench fixture tests only.' \
	  '  make test-llama-local        Run optional local GGUF sidecar provider test.' \
	  '  make test-synthetic-small    Run small Gumbel correctness benchmark.' \
	  '  make paper-small             Run small no-network paper reproducibility pipeline.' \
	  '  make paper-full              Prepare full local-model experiment skeleton.' \
	  '  make test-paper-full-missing Verify paper-full fails clearly without model env.' \
	  '  make test-acceptance         Run acceptance tests against an already running server.' \
	  '  make test-acceptance-local   Start a local llama-server, run acceptance tests, stop it.' \
	  '  make watch                   Re-run tests on source changes and send desktop notifications.' \
	  '  make clean-deps              Remove downloaded external dependencies.'

install:
	$(RACO) pkg install --auto

env: watch-deps deps model

watch-deps:
	scripts/bootstrap-watch-tools.sh

deps:
	LLAMA_CPP_DIR="$(LLAMA_CPP_DIR)" \
	LLAMA_CPP_REF="$(LLAMA_CPP_REF)" \
	LLAMA_CPP_BUILD_DIR="$(LLAMA_CPP_BUILD_DIR)" \
	scripts/bootstrap-llama-cpp.sh

model:
	RACK_LLM_MODEL="$(RACK_LLM_MODEL)" scripts/download-model.sh

server:
	"$(LLAMA_SERVER)" \
	  --model "$(RACK_LLM_MODEL)" \
	  --host 127.0.0.1 \
	  --port 8080 \
	  --ctx-size 512 \
	  --no-webui

lint:
	RACO="$(RACO)" scripts/lint.sh
	$(RACO) test tests/unit/public-api-contract-test.rkt tests/unit/source-policy-test.rkt

ci: lint test test-integration test-readme test-examples test-synthetic-small paper-small test-paper-full-missing

test:
	$(RACO) test tests/unit

test-integration:
	$(RACO) test tests/integration

test-all:
	$(RACO) test tests

test-readme:
	RACO="$(RACO)" sh scripts/test-readme.sh

test-examples:
	sh scripts/test-examples.sh

test-weak-ifbench-fixture:
	$(RACO) test tests/unit/weak-ifbench-dataset-test.rkt

test-llama-local:
	$(RACO) test tests/integration/llama-local-provider-test.rkt

test-synthetic-small:
	sh scripts/test-synthetic-small.sh

paper-small:
	racket experiments/paper-small.rkt

paper-full:
	sh scripts/paper-full.sh

test-paper-full-missing:
	@if RACK_LLM_MODEL= sh scripts/paper-full.sh >/tmp/rack-llm-paper-full.out 2>/tmp/rack-llm-paper-full.err; then \
	  cat /tmp/rack-llm-paper-full.out; \
	  cat /tmp/rack-llm-paper-full.err >&2; \
	  printf '%s\n' 'paper-full unexpectedly succeeded without RACK_LLM_MODEL' >&2; \
	  exit 1; \
	else \
	  grep -q 'paper-full requires RACK_LLM_MODEL=' /tmp/rack-llm-paper-full.err; \
	fi

test-acceptance:
	RACK_LLM_ACCEPTANCE=1 \
	RACK_LLM_LLAMA_SERVER="$(RACK_LLM_LLAMA_SERVER)" \
	$(RACO) test tests/acceptance

test-acceptance-local: model
	LLAMA_SERVER="$(LLAMA_SERVER)" \
	RACK_LLM_MODEL="$(RACK_LLM_MODEL)" \
	RACK_LLM_TEST_PORT="$(RACK_LLM_TEST_PORT)" \
	RACO="$(RACO)" \
	scripts/run-acceptance-local.sh

watch:
	WATCH_TARGET="$(WATCH_TARGET)" scripts/watch.sh

clean-deps:
	rm -rf .deps
