PYTHON ?= ../../.venv-realbench/bin/python
RACO ?= raco
PLTCOLLECTS ?= /mnt/storage/work:
RACK_LLM_GGUF_MODEL ?= /mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf

.PHONY: ci dataset compile test smoke run

ci: dataset compile test

dataset:
	$(PYTHON) code/build_pwsg_dataset_012.py

compile:
	PLTCOLLECTS="$(PLTCOLLECTS)" $(RACO) make code/racket_pwsg_pipeline.rkt

test:
	$(PYTHON) code/test_pwsg_pipeline.py -q

smoke:
	cd ../.. && RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" \
	  $(RACO) test tests/e2e-real-test.rkt

run:
	PLTCOLLECTS="$(PLTCOLLECTS)" RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" \
	  racket code/racket_pwsg_pipeline.rkt --specs ../../data/012_pwsg_specs.jsonl \
	  --output results/012_pwsg_generation_raw.jsonl --models-dir results/weak-models
