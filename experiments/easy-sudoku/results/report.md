# Mini-Sudoku 4x4 Results

Thirty uniquely solvable puzzles: ten each with 2, 3, and 4 blanks.

Protocol: Qwen3-1.7B Q4_K_M through llama.cpp's native Completion endpoint with the Qwen ChatML template and thinking disabled, temperature 0.8, deterministic per-case seeds, ten requested candidates, and top-64 token probabilities for rack-llm.

Server: NVIDIA GeForce GTX 1650 4 GB, Intel Core i7-9750H, context 8192, one slot, full GPU offload, and flash attention.

## Overall

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 1/30 | 7/30 | 300/300 | 300/300 | 0 | 0.0s |
| baseline | 1/30 | 2/30 | 287/300 | 84/300 | 300 | 54.8s |
| baseline-unique | 1/30 | 4/30 | 147/300 | 147/300 | 2951 | 499.5s |
| rack-llm | 2/30 | 11/30 | 300/300 | 300/300 | 1427 | 293.7s |

## By Difficulty

### 2 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 1/10 | 6/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 1/10 | 1/10 | 97/100 | 18/100 | 100 | 13.5s |
| baseline-unique | 1/10 | 2/10 | 29/100 | 29/100 | 1000 | 126.9s |
| rack-llm | 2/10 | 9/10 | 100/100 | 100/100 | 310 | 73.2s |

### 3 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/10 | 1/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 0/10 | 1/10 | 96/100 | 37/100 | 100 | 19.8s |
| baseline-unique | 0/10 | 2/10 | 59/100 | 59/100 | 1000 | 166.3s |
| rack-llm | 0/10 | 2/10 | 100/100 | 100/100 | 460 | 94.6s |

### 4 blanks

| Mode | pass@1 | pass@10 | Valid | Unique | Calls | Time |
|---|---:|---:|---:|---:|---:|---:|
| random-unique | 0/10 | 0/10 | 100/100 | 100/100 | 0 | 0.0s |
| baseline | 0/10 | 0/10 | 94/100 | 29/100 | 100 | 21.5s |
| baseline-unique | 0/10 | 0/10 | 59/100 | 59/100 | 951 | 206.2s |
| rack-llm | 0/10 | 0/10 | 100/100 | 100/100 | 657 | 126.0s |

## Uncertainty

- `baseline` pass@10: 2/30 (6.7%), 95% Wilson CI [1.8%, 21.3%].
- `baseline-unique` pass@10: 4/30 (13.3%), 95% Wilson CI [5.3%, 29.7%].
- `rack-llm` pass@10: 11/30 (36.7%), 95% Wilson CI [21.9%, 54.5%].

## Result

- Ten unique random guesses are expected to solve approximately 8.20/30 puzzles; the recorded random control solved 7/30.
- `rack-llm` solved 11/30, compared with 7/30 for random unique enumeration and 4/30 for ordinary unique resampling. This is an observed improvement in this run.
- `rack-llm` used 1427 one-token oracle calls and 293.7s. `baseline-unique` used 2951 full generation requests and 499.5s.
- Call counts are not directly equivalent: each rack-llm call requests one token distribution, while each baseline call requests a complete answer.
- The model-backed modes solved different puzzle IDs, which is consistent with a noisy low-probability search.
- The result supports the hypothesis that rack-llm search can recover useful lower-probability answers more effectively than independent sampling on tasks the model can partially solve. The 30-puzzle sample is still too small for a strong statistical claim.

Solved cases:

- `random-unique`: easy-2-01, easy-2-03, easy-2-04, easy-2-06, easy-2-07, easy-2-10, easy-3-05
- `baseline`: easy-2-01, easy-3-02
- `baseline-unique`: easy-2-01, easy-2-09, easy-3-02, easy-3-04
- `rack-llm`: easy-2-01, easy-2-02, easy-2-03, easy-2-05, easy-2-06, easy-2-07, easy-2-08, easy-2-09, easy-2-10, easy-3-02, easy-3-04

## Interpretation

- `random-unique` measures the score obtainable by enumerating valid arrays without using the model.
- `baseline` measures ten ordinary generations, including format errors and duplicates.
- `baseline-unique` measures ordinary resampling until ten unique valid arrays are collected, capped at 100 requests per puzzle.
- `rack-llm` measures ten unique grammar-valid arrays from one lazy search.
- For unique modes, pass@1 refers to the first retained valid candidate, not necessarily the first model request.
- A useful rack-llm result must beat `random-unique` and should be compared with `baseline-unique` together with calls and elapsed time.
