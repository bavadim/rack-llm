# Experiment 012: PWSG on a local model

This experiment evaluates sequence-level programmatic weak guidance with the
native llama.cpp backend. It does not use the removed manual score API.

## Design

The input contains one hard-bounded `text` specification per IFBench row and
three rule conditions: `clean`, `noisy_20`, and `noisy_40`. Each template and
noise group receives its own weak model. Calibration draws hard-valid candidates
and uses `N = max(256, 20 M)`, where `M` is the number of weak rules.

The runner compares four methods under the same hard language:

- `pwsg_cars`: posterior is the CARS terminal mass;
- `hard_only_cars`: no weak terminal mass;
- `posterior_rerank`: best of four hard samples;
- `posterior_rejection`: ordinary independent posterior rejection.

Rules are evaluated only on completed candidates. `ban` remains a hard scoped
veto and is excluded from the weak observation vector.

## Commands

```bash
make -C experiments/012_real_model_benchmark ci
make -C experiments/012_real_model_benchmark smoke
make -C experiments/012_real_model_benchmark run
```

`ci` is deterministic and does not load a model. `smoke` runs the real-backend
PWSG contract with controlled synthetic calibration data. `run` uses the paper settings and writes
`results/012_pwsg_generation_raw.jsonl` plus serialized models under
`results/weak-models/`.

The legacy `012_soft_*` files predate PWSG and are not inputs to this experiment.
