ROOT := $(abspath ..)
SYSTEM_PYTHON ?= python3
VENV ?= $(CURDIR)/.venv
PYTHON := $(VENV)/bin/python
VENV_STAMP := $(VENV)/.requirements.stamp
STATIC_VENV ?= $(CURDIR)/.venv-static
STATIC_PYTHON := $(STATIC_VENV)/bin/python
STATIC_STAMP := $(STATIC_VENV)/.requirements.stamp
RUN_ID ?=
export PYTHONPATH := $(CURDIR)/src

.PHONY: bootstrap bootstrap-static validate-data preflight test static-ci freeze run-hard run-audit run-aggregation run-generation run-noise run-replication run-mixed run-design power record-design run-all analyze archive

$(STATIC_STAMP): requirements-static.txt
	test -x "$(STATIC_PYTHON)" || $(SYSTEM_PYTHON) -m venv "$(STATIC_VENV)"
	$(STATIC_PYTHON) -m pip install -r requirements-static.txt
	touch "$@"

bootstrap-static: $(STATIC_STAMP)
	PYTHONPATH=$(CURDIR)/src $(STATIC_PYTHON) -m pwseq_experiments bootstrap-static

static-ci: bootstrap-static
	$(MAKE) -C $(ROOT) native-regex
	PYTHONPATH=$(CURDIR)/src $(STATIC_PYTHON) -m pwseq_experiments validate-data
	cd $(ROOT) && PLTCOLLECTS="$(abspath $(ROOT)/..):" raco test tests/loc-test.rkt tests/contract-test.rkt tests/e2e-sampler-test.rkt
	PYTHONPATH=$(CURDIR)/src $(STATIC_PYTHON) -m unittest discover -s tests -v
	cd $(ROOT) && git diff --exit-code

$(VENV_STAMP): requirements.txt
	test -x "$(PYTHON)" || $(SYSTEM_PYTHON) -m venv "$(VENV)"
	$(PYTHON) -m pip install -r requirements.txt
	touch "$@"

bootstrap: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments bootstrap

validate-data: $(VENV_STAMP)
	$(PYTHON) -m pwseq_experiments validate-data

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
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" hard

run-audit: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" audit

run-aggregation: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" aggregation

run-generation: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" generation

run-noise: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" noise

run-replication: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" replication

run-mixed: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" mixed

run-design: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" design

power: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments power --run-id "$(RUN_ID)"

record-design: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments record-design --run-id "$(RUN_ID)"

run-all: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments run --run-id "$(RUN_ID)" all

analyze: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments analyze --run-id "$(RUN_ID)"

archive: $(VENV_STAMP)
	@test -n "$(RUN_ID)" || { echo 'RUN_ID is required' >&2; exit 2; }
	$(PYTHON) -m pwseq_experiments archive --run-id "$(RUN_ID)"
