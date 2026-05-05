RACO ?= raco
LLAMA_CPP_DIR ?= .deps/llama.cpp
LLAMA_CPP_REF ?= master
LLAMA_CPP_BUILD_DIR ?= $(LLAMA_CPP_DIR)/build
LLAMA_SERVER ?= $(LLAMA_CPP_BUILD_DIR)/bin/llama-server
RACK_LLM_MODEL ?= models/qwen2.5-0.5b-instruct-q4_k_m.gguf
RACK_LLM_LLAMA_SERVER ?= http://127.0.0.1:8080
RACK_LLM_TEST_PORT ?= 18080

.PHONY: help install env deps model server test test-all test-acceptance test-acceptance-local clean-deps

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install                 Install the Racket package with raco.' \
	  '  make env                     Build llama.cpp and download the default model.' \
	  '  make deps                    Clone and build llama.cpp with LLGuidance support.' \
	  '  make model                   Download the default small GGUF model.' \
	  '  make server                  Run llama-server in the foreground.' \
	  '  make test                    Run unit tests through raco.' \
	  '  make test-all                Run all tests through raco; acceptance skips unless enabled.' \
	  '  make test-acceptance         Run acceptance tests against an already running server.' \
	  '  make test-acceptance-local   Start a local llama-server, run acceptance tests, stop it.' \
	  '  make clean-deps              Remove downloaded external dependencies.'

install:
	$(RACO) pkg install --auto

env: deps model

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

test:
	$(RACO) test tests/unit

test-all:
	$(RACO) test tests

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

clean-deps:
	rm -rf .deps
