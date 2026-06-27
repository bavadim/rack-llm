# Weak-IFBench Protocol

Weak-IFBench evaluates whether weak, noisy constraint heuristics can improve
candidate selection without using the gold verifier during selection.

Gold verifier is never used for candidate selection; it is used only for
evaluation.

## Inputs

Each task contains:

- a task id;
- a prompt shown to the generation method;
- a list of constraint specs;
- a gold verifier id used only after candidate selection;
- metadata such as source split or category.

The local JSONL adapter accepts one JSON object per line:

```json
{
  "id": "task-1",
  "prompt": "Write an answer...",
  "constraints": [
    {"id": "phrase", "type": "phrase-presence", "params": {"phrase": "approved"}}
  ],
  "gold_verifier_id": "embedded",
  "metadata": {"split": "calibration"}
}
```

`rack-llm/experiments/weak-ifbench/dataset` exposes `load-ifbench-jsonl` and an
explicit `run-gold-verifier` evaluation call. For real IFBench exports,
`metadata.verifier_command` may point at a local verifier command that accepts
`--task-id` and `--candidate-file` and prints verifier JSON.

The method may read the prompt, constraint specs, split name, and weak
heuristics derived from the constraint specs. The method must not read the gold
verifier output for any candidate in the same selection run.

## Candidate Selection

At budget `B`, the provider produces up to `B` candidate answers. Candidate
selection may use:

- model scores or sampler scores;
- grammar validity;
- hard rules that reject invalid candidates;
- weak heuristic rule observations;
- unsupervised Dawid-Skene posteriors fit on the calibration split;
- thresholded acceptance config chosen before test evaluation.

Candidate selection must not use:

- prompt-level gold success labels from the test split;
- constraint-level gold labels from the test split;
- verifier messages for candidates being selected;
- manual tuning on test-set outcomes.

## Weak Heuristics

Weak heuristics are deterministic local rules generated from constraint specs.
They return `accept`, `reject`, or `abstain`. They are intentionally imperfect:
for example, word-count splitting may mishandle punctuation, phrase matching may
miss Unicode normalization, and simple sentence splitting may mishandle
abbreviations.

Weak heuristic outputs are observations for aggregation methods. They are not
gold labels.

`rack-llm/experiments/weak-ifbench/heuristics` supports the first release
constraint groups:

- `word-count`
- `sentence-count`
- `phrase-presence`
- `forbidden-phrase`
- `section-header` / `header-format`
- `json-structure`
- `markdown-structure`

Each supported group emits at least two soft weak rules. Unsupported constraint
types return no rules from `weak-rules-for-constraint` and are listed by
`weak-rule-coverage-for-task`, so coverage gaps are explicit skipped constraints
rather than silent passes.

## Gold Verifier

The gold verifier is the evaluation oracle. For each selected candidate it
returns:

- prompt-level success;
- per-constraint success;
- an optional diagnostic message.

The verifier may also be run over all candidates generated within budget to
compute `Oracle@B`. That oracle result is still evaluation-only and cannot feed
back into selection.

## Data Split

Use three logical splits:

- `calibration`: fit Dawid-Skene and choose fixed threshold configs without gold
  labels for DS fitting.
- `dev`: optional split for choosing manual hyperparameters and checking
  implementation regressions.
- `test`: final reported metrics.

Dawid-Skene is trained from weak rule observations on the calibration split.
Gold labels are not used in the unsupervised DS fit. If DS orientation is fixed
with an anchor rule, the anchor is declared before test evaluation. If
`dev-gold` orientation is used, it is fit on dev only and then frozen.

`rack-llm/experiments/weak-ifbench/runner.rkt` provides deterministic task-id
splitting:

```bash
racket experiments/weak-ifbench/runner.rkt \
  --data weak-ifbench.jsonl \
  --provider llama-local \
  --model model.gguf \
  --budgets 1,2,4,8,16 \
  --seed 42 \
  --out runs/weak-ifbench
```

The runner writes `calibration/`, `dev/`, `test/`, `models/ds-model.json`,
`models/thresholds.json`, `experiment-config.json`, `metrics.csv`, and an
explicit `leakage-boundary.json`. Calibration DS fitting uses weak observations
only. The dev split may use the gold verifier for threshold tuning. Test gold is
used only after candidate selection for final evaluation.

`experiment-config.json` freezes provider, model, prompt template, grammar,
weak rule ids, budgets, seed, split ids, and data path. Its `config_hash` is
also written to run metadata and prefixed onto metrics rows.

## Metrics

`rack-llm/experiments/metrics` defines the selection and calibration metrics.
Each `eval-record` is one prompt/run result at budget `B`.

- `GoldSuccess@B`: fraction of records where the selected candidate satisfies
  the gold target.
- `Oracle@B`: fraction of records where at least one candidate within the
  budget satisfies the gold target.
- `SelectionEfficiency@B`: `GoldSuccess@B / Oracle@B`. If `Oracle@B` is zero,
  the Racket API returns `+nan.0`; JSON output emits `null`.
- `ConstraintSuccess@B`: mean success across all constraint-level gold labels.
- `Brier`: mean squared error between `eta` and the prompt-level gold success
  label.
- `ECE`: expected calibration error over equal-width `eta` bins.
- `AUROC`: pairwise area under the ROC curve from `eta` against prompt-level
  gold success, with ties receiving half credit.
- `duplicate-rate`: mean duplicate rate recorded per prompt/run.
- `avg-candidates`: mean budget in `eval-record`.
- `provider_k`: mean explicit top-K setting for truncated runs, or empty for
  exact runs.
- `truncated_mass_mean`: mean discarded softmax mass when a truncated provider
  records it, or empty when unavailable.

Use `summarize-eval-records` for a stable metrics hash. `write-metrics-json`
emits JSON-safe values, and `write-metrics-csv` emits a fixed scalar column
order for experiment tables.

## Baselines

Report at least:

- raw model rank: select the first candidate within budget;
- majority vote: per-constraint weak-rule majority score;
- equal weights: per-constraint accept ratio over accept/reject observations;
- Dawid-Skene: per-constraint posterior model with thresholded acceptance.

Majority and equal-weight scores are comparable scalar scores in `[0, 1]`, but
they are not calibrated posteriors.

`rack-llm/experiments/weak-ifbench/methods` defines the common method interface
and method ids:

- `pass1`
- `independent-sampling`
- `independent-majority`
- `independent-ds`
- `gumbel-majority`
- `gumbel-ds`
- `oracle-verifier`

`oracle-verifier` uses the gold verifier to select a candidate and must be
reported only as an oracle upper bound. The non-oracle methods use the same
task, candidate generator, weak rules, and budget; they differ only in the
selection rule.

## Outputs

A run writes:

- candidate traces with rule observations, posterior-like scores, acceptance
  decisions, and diagnostics;
- metrics JSON/CSV from `summarize-eval-records`;
- complexity CSV from `experiments/analyze-complexity.rkt` when trace counters
  are available;
- frozen experiment config containing provider, model, budget, seed, split, and
  aggregation mode.

Paper table artifacts are generated from a completed run directory:

```bash
racket experiments/weak-ifbench/summarize.rkt runs/weak-ifbench --out tables/
```

The summarizer writes `main_results.csv`, `calibration_metrics.csv`,
`cost_metrics.csv`, `ablation_results.csv`, and `summary.md`. These files are
derived from run metrics/config artifacts, so no manual spreadsheet edits are
required.

For a full local-model experiment skeleton:

```bash
RACK_LLM_MODEL=/models/qwen.gguf make paper-full
```

If `RACK_LLM_MODEL` is missing or points at a nonexistent file, the target exits
with a clear error. The template config is `configs/paper-full.example.json`;
CI checks only the missing-model error path.
