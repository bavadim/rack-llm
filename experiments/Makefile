ROOT := $(abspath ..)
SYSTEM_PYTHON ?= python3
VENV ?= $(CURDIR)/.venv
PYTHON := $(VENV)/bin/python
VENV_STAMP := $(VENV)/.requirements.stamp
export PYTHONPATH := $(CURDIR)/src

.PHONY: bootstrap prepare preflight test freeze run-hard run-audit run-aggregation run-generation run-noise run-replication run-all analyze archive

$(VENV_STAMP): requirements.txt
	test -x "$(PYTHON)" || $(SYSTEM_PYTHON) -m venv "$(VENV)"
	$(PYTHON) -m pip install -r requirements.txt
	touch "$@"

bootstrap: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments bootstrap

prepare: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments prepare

preflight: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments preflight

test: $(VENV_STAMP)
	cd $(ROOT) && PLTCOLLECTS="$(abspath $(ROOT)/..):" raco make \
		main.rkt backend.rkt experiments/racket/rack_runner.rkt \
		experiments/racket/synthetic_exactness.rkt experiments/racket/validate_hard.rkt
	cd $(ROOT) && PLTCOLLECTS="$(abspath $(ROOT)/..):" raco test \
		tests/loc-test.rkt tests/contract-test.rkt tests/e2e-sampler-test.rkt
	$(PYTHON) -m unittest discover -s tests -v

freeze: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments freeze

run-hard: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run hard

run-audit: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run audit

run-aggregation: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run aggregation

run-generation: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run generation

run-noise: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run noise

run-replication: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run replication

run-all: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments run all

analyze: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments analyze

archive: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments archive
