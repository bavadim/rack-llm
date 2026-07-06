# Design

`rack-llm` is built around one abstraction:

```text
Guide[A] = weighted set of (string, value, log-score)
```

Closed guides define hard languages. A string outside the language has score
`-inf.0`; a valid neutral string has score `0.0`.

```racket
(seq "Answer: " (select "yes" "no"))
```

`text` is the only open-world segment. It accepts arbitrary generated text
within a budget, then observers adjust score or veto text:

```racket
(text (rank 3 "patent")
      (ban "TODO"))
```

`rank` is contextual. In a closed context it scores a closed branch:

```racket
(select (rank 2 "approve") "reject")
```

Inside `text`, the same `rank` becomes a watcher:

```racket
(text (rank 2 "approve"))
```

`bind` passes a generated value to ordinary Racket code and continues with the
returned guide:

```racket
(bind (rx #px"[0-9]")
      (lambda (n)
        (lit (number->string (+ 1 (string->number n))))))
```

Generation uses provider logits plus local guide deltas:

```text
adjusted(v) = logit(v) + guide_adjustment(v)

guide_adjustment(v) =
  -inf                                      if the guide transition is dead
  beta * (Delta score + lambda * Delta potential) otherwise
```

The public API is intentionally small. Providers supply vocabularies and logits;
the llama.cpp bridge is a separate sidecar adapter for full-vocabulary logits.
