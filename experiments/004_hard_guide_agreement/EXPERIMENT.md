# Experiment 004: Hard Guide Agreement With IFBench Verifier

## Introduction

Hard-generation benchmarks are only meaningful when the generated grammar agrees
with the official task verifier. Otherwise `FOUND_WRONG` can reflect a grammar
translation error rather than a decoding failure. This experiment validates the
hard guide specs from Experiment 003 against the pinned IFBench verifier and
builds the hard benchmark subset.

## Methods

`code/build_hard_agreement.py` downloads the pinned IFBench runtime files into
`vendor/ifbench`, imports the official instruction registry, and evaluates a
synthetic validation pool per row. The validation pool contains generated
builder-valid strings and builder-invalid strings. For each candidate it records:

- official IFBench verifier result
- our hard spec checker result
- Guidance spec checker result
- Outlines spec checker result

Rows are included in `hard_ifbench_subset.jsonl` when all three spec checkers
reach agreement at least `0.99` with the official verifier.

Reproduce with a Python environment containing `requirements.txt`:

```bash
python3 -m venv /tmp/rack-llm-ifbench-venv
/tmp/rack-llm-ifbench-venv/bin/python -m pip install -r experiments/004_hard_guide_agreement/requirements.txt
/tmp/rack-llm-ifbench-venv/bin/python experiments/004_hard_guide_agreement/code/build_hard_agreement.py
/tmp/rack-llm-ifbench-venv/bin/python experiments/004_hard_guide_agreement/code/test_hard_agreement.py
```

## Results

The experiment writes:

- `data/hard_ifbench_subset.jsonl`
- `data/hard_guide_agreement_report.csv`
- `data/hard_guide_agreement_failures.jsonl`

It also writes identical copies under
`experiments/004_hard_guide_agreement/data/`. If fewer than 50 rows pass
agreement validation, the script creates `hard_subset_low_coverage.md` with a
family-level failure breakdown.

## Discussion

This experiment still does not run any LLM. It validates grammar/checker
agreement only. Guidance and Outlines are represented by the serializable specs
from Experiment 003; backend runtime integration is deferred to the hard solve
benchmark. The report marks these baseline checks as spec-level checks rather
than installed-backend checks.
