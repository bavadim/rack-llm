# Architecture

The library has one exact generation path.

```text
Program AST --compile-spec--> hard + weak token-native Guidance
     |                         |
     +--schema/fingerprint     +--hard allowed tokens and scoped bans
                                      |
stateful Provider logits ------------+--> fractional CARS trie
                                              |
hard-valid terminal --> WeakObservation --> posterior terminal mass
```

Programs are explicit immutable AST values. `CompiledSpec` compiles them once,
validate the PWSG profile, enumerate structural weak rules, and create stable
fingerprints. `rx` is supported by hard-only CARS but is outside the static
PWSG profile.

Guidance states are local to one proposal. A `control` records token boundaries
and runs only hard bans online. Prefer/avoid rules are evaluated after a
hard-valid terminal. Completed control occurrences are retained as captures;
inactive branches abstain and repeated occurrences aggregate by any-match.

A reusable Generator borrows a `CompiledSpec` and owns prompt ids, RNG, the fractional
CARS trie and immutable terminal evaluations. It borrows a Model through a
lease. Provider sessions are per-attempt and always closed with `dynamic-wind`.

CARS unknown mass is one, hard-invalid mass is zero, and an evaluated weak
terminal has mass `posterior` or zero below threshold. Acceptance uses
`mass / old-envelope`; the trie update happens after the Bernoulli draw.

The native regex ownership chain remains `state -> regex -> vocabulary`.
Token domains use all/only/except representations. llama.cpp consumes them with
sparse trie child masses in a native exact factor sampler, avoiding one FFI call
per vocabulary token.
`RACK_LLM_REGEX_NATIVE_LIB` and `RACK_LLM_LLAMA_NATIVE_LIB` allow isolated
sanitizer builds without replacing release libraries.
