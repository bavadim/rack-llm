PYTHON ?= ../../.venv-realbench/bin/python
RACO ?= raco
PLTCOLLECTS ?= /mnt/storage/work:
RACK_LLM_GGUF_MODEL ?= /mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf

.PHONY: ci compile test

ci: compile test

compile:
	PLTCOLLECTS="$(PLTCOLLECTS)" $(RACO) make \
	  code/racket_choice_batch.rkt \
	  code/racket_ours_soft_smoke.rkt \
	  code/racket_ours_soft_batch.rkt \
	  code/racket_soft_candidate_pool.rkt

test:
	RACK_LLM_GGUF_MODEL="$(RACK_LLM_GGUF_MODEL)" $(PYTHON) -m pytest -q code/test_real_model_benchmark.py
