# Pencil Puzzle Bench Results

Dataset: PPBench `golden_30`, Qwen2.5-0.5B-Instruct Q4_K_M, ten requested
grammar-valid outputs per puzzle, and top-64 token probabilities.

Hardware: NVIDIA GeForce GTX 1650 4 GB and Intel Core i7-9750H.

## Completed Rack-LLM Run

| Metric | Result |
|---|---:|
| Puzzles | 30 |
| pass@10 | 0/30 |
| Valid JSON | 296/300 |
| Errors | 0/30 |
| Elapsed | 3597.1s |

This completed run included memoization and early deduplication inside
`at-least-once`, but preceded final stream deduplication by rendered text.
Consequently, some of the ten returned candidates were duplicate strings.

## Search Findings

- Without memoization, ambiguous repetition around `gen` repeatedly parsed
  the same suffixes and could spend seconds in `build-children`.
- Memoizing continuation parsing reduced the common `build-children` time
  from seconds to milliseconds and allowed all 30 puzzles to complete.
- Different internal parses could still render to the same answer. Final
  sampler deduplication now removes those duplicates by full rendered text.
- Finding ten unique answers is necessarily slower than returning duplicate
  parses of the same answer.

## Interpretation

The 0/30 score shows that this 0.5B model cannot solve the selected PPBench
tasks under this protocol. It does not establish whether constrained
resampling helps a model capable of solving the puzzles.

A final apples-to-apples baseline comparison was not recorded for this
benchmark because the model failed every constrained attempt and the
full unique-output run was interrupted. The mini-Sudoku experiment provides
the completed comparison among ordinary generation, ordinary unique
resampling, random valid enumeration, and rack-llm search.
