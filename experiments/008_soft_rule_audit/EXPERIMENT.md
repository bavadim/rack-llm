# Experiment 008: Soft Rule Quality Audit

## Introduction

Soft rules should be weak but nontrivial. This experiment audits the clean and
noisy watcher sets from Experiment 007 against a real native-Qwen candidate pool
and the pinned IFBench official verifier.

## Methods

The runner consumes `data/012_soft_candidate_pool.jsonl`, which is produced by
the native llama.cpp Qwen path in Experiment 012. If that real pool is absent or
comes from an old backend, the audit fails instead of creating placeholder
candidates. The audit runner imports the official IFBench verifier from the
pinned vendored runtime used by Experiment 004; the rule builder from Experiment
007 still does not import or call verifier code.

For each watcher, the audit computes coverage, precision, lift, and nearest
Jaccard overlap. Clean watchers are accepted only when they are nontrivial,
directionally predictive, and not near-duplicates. Rows are kept in the audited
rules file when enough accepted clean rules remain.

Reproduce:

```bash
/tmp/rack-llm-ifbench-venv/bin/python experiments/008_soft_rule_audit/code/run_soft_rule_audit.py
/tmp/rack-llm-ifbench-venv/bin/python experiments/008_soft_rule_audit/code/test_soft_rule_audit.py
```

## Results

The runner writes:

- `data/soft_rule_candidate_pool.jsonl`
- `data/soft_rule_audit.csv`
- `data/soft_ifbench_rules_audited.jsonl`
- `data/soft_rule_audit_failures.md` when fewer than 150 rows survive

The 150-row survival target is impossible for the current pinned soft subset
because Experiment 007 emits 78 soft-supported rows. The failure report records
this and gives a family breakdown.

## Discussion

This is an audit, not a decoding benchmark. Its role is to catch trivial or
duplicative watchers before later soft-generation experiments consume the rule
sets.
