# Mini-Sudoku 4x4 Results

Thirty uniquely solvable puzzles: ten each with 3, 4, and 5 blanks.

Protocol: Qwen2.5-0.5B-Instruct Q4_K_M through llama.cpp's native Completion endpoint, temperature 0.8, deterministic per-case seeds, ten requested candidates, and top-64 token probabilities for rack-llm.

Server: NVIDIA GeForce GTX 1650 4 GB, Intel Core i7-9750H, context 2048, one slot, full GPU offload, and flash attention.

## Overall

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/30 | 1/30 | 300/300 | 300/300 | 0 | 0.0s |
| baseline | 0/30 | 1/30 | 25/300 | 24/300 | 300 | 21.7s |
| baseline-unique | 1/30 | 1/30 | 164/300 | 164/300 | 2734 | 262.2s |
| rack-llm | 1/30 | 1/30 | 300/300 | 300/300 | 3224 | 720.9s |

## By Difficulty

### 3 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/10 | 1/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 0/10 | 1/10 | 9/100 | 9/100 | 100 | 5.8s |
| baseline-unique | 1/10 | 1/10 | 65/100 | 65/100 | 861 | 42.7s |
| rack-llm | 1/10 | 1/10 | 100/100 | 100/100 | 564 | 134.3s |

### 4 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/10 | 0/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 0/10 | 0/10 | 14/100 | 13/100 | 100 | 7.5s |
| baseline-unique | 0/10 | 0/10 | 74/100 | 74/100 | 873 | 94.8s |
| rack-llm | 0/10 | 0/10 | 100/100 | 100/100 | 833 | 190.2s |

### 5 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/10 | 0/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 0/10 | 0/10 | 2/100 | 2/100 | 100 | 8.5s |
| baseline-unique | 0/10 | 0/10 | 25/100 | 25/100 | 1000 | 124.7s |
| rack-llm | 0/10 | 0/10 | 100/100 | 100/100 | 1827 | 396.4s |

## Uncertainty

- `baseline` pass@10: 1/30 (3.3%), 95% Wilson CI [0.6%, 16.7%].
- `baseline-unique` pass@10: 1/30 (3.3%), 95% Wilson CI [0.6%, 16.7%].
- `rack-llm` pass@10: 1/30 (3.3%), 95% Wilson CI [0.6%, 16.7%].

## Result

- Ten unique random guesses are expected to solve approximately 2.05/30 puzzles; the recorded random control solved 1/30.
- `rack-llm` solved 1/30, so this run does not show an improvement over random unique enumeration.
- `baseline-unique` solved 1/30 and therefore also does not establish model reasoning above the random expectation.
- `rack-llm` used 3224 one-token oracle calls and 720.9s. `baseline-unique` used 2734 full generation requests and 262.2s.
- Call counts are not directly equivalent: each rack-llm call requests one token distribution, while each baseline call requests a complete answer.
- All model-backed modes solved the same puzzle set. This suggests the result comes from a narrow model capability rather than from the resampling strategy.
- Therefore this experiment confirms rack-llm's format and deduplication guarantees, but does not confirm that its search improves semantic puzzle solving for Qwen2.5-0.5B.

Solved cases:

- `random-unique`: easy-3-07
- `baseline`: easy-3-09
- `baseline-unique`: easy-3-09
- `rack-llm`: easy-3-09

## Interpretation

- `random-unique` measures the score obtainable by enumerating valid arrays without using the model.
- `baseline` measures ten ordinary generations, including format errors and duplicates.
- `baseline-unique` measures ordinary resampling until ten unique valid arrays are collected, capped at 100 requests per puzzle.
- `rack-llm` measures ten unique grammar-valid arrays from one lazy search.
- For unique modes, pass@1 refers to the first retained valid candidate, not necessarily the first model request.
- A useful rack-llm result must beat `random-unique` and should be compared with `baseline-unique` together with calls and elapsed time.
