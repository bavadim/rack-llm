RACO ?= raco

.PHONY: help install lint ci test examples bench

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make install       Install the Racket package with raco.' \
	  '  make lint          Compile the library and tests.' \
	  '  make test          Run tests.' \
	  '  make examples      Run public examples.' \
	  '  make bench         Run local runtime microbenchmarks.' \
	  '  make ci            Run lint and tests.'

install:
	$(RACO) pkg install --auto

lint:
	$(RACO) make core.rkt guides.rkt runtime.rkt provider.rkt sampling.rkt weight.rkt main.rkt llama-cpp.rkt tests/core-test.rkt

ci: lint test examples

test:
	$(RACO) test tests

examples:
	@for example in examples/*.rkt; do racket "$$example"; done

bench:
	@mkdir -p bench/results
	racket bench/full_vocab_linear.rkt | tee bench/results/full_vocab_linear.csv
	racket bench/soft_topk_watch.rkt | tee bench/results/soft_topk_watch.csv
