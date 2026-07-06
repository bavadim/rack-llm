# 022. Зафиксировать reproducibility package для real benchmark

## SMART goal

Собрать полный reproducibility package для `012_*` paper-grade экспериментов: configs, commands, package versions, model metadata, artifact hashes, and reproduction instructions.

## Зачем это нужно

Даже хорошие результаты бесполезны для статьи, если нельзя точно понять, как они получены и проверить, что artifacts не смешаны с pilot/synthetic outputs.

## Scope

Создать:

```text
experiments/012_real_model_benchmark/config.lock.json
experiments/012_real_model_benchmark/ARTIFACT_MANIFEST.json
experiments/012_real_model_benchmark/REPRODUCE.md
experiments/012_real_model_benchmark/results/command_log.txt
```

Зафиксировать:

- model path/revision/hash;
- tokenizer hash;
- CUDA/GPU metadata;
- package versions;
- benchmark config;
- exact commands;
- sha256 for all final artifacts.

## Out of scope

- Не менять результаты.
- Не запускать новые experiments.
- Не редактировать statistical criteria.

## How

- Скрипт manifest builder считает sha256 для всех `012_*` raw/summary/final files.
- `config.lock.json` содержит resolved config, не example config.
- `REPRODUCE.md` дает one-command или step-by-step reproduction.
- Старые pilot results явно помечены as non-paper-grade.

## Required outputs

```text
experiments/012_real_model_benchmark/config.lock.json
experiments/012_real_model_benchmark/ARTIFACT_MANIFEST.json
experiments/012_real_model_benchmark/REPRODUCE.md
experiments/012_real_model_benchmark/results/command_log.txt
```

## Unit tests

- `test_manifest_hashes_existing_files`
- `test_config_lock_has_model_and_package_versions`
- `test_reproduce_mentions_no_synthetic_claims`
- `test_all_final_artifacts_have_hash`

## DoD

- All required files created.
- Every final `012_*` artifact has sha256.
- Reproduction instructions include environment setup and benchmark commands.
- `make ci` and all `012` tests pass.
- Pilot artifacts are clearly labeled as non-paper-grade.
