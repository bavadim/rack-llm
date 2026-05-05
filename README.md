# rack-llm

`rack-llm` is a small Racket library for building lazy chat grammar ASTs and
reducing them with `llama-server`. The core is written in Typed Racket.

## Install

From this repository:

```bash
raco pkg install --auto
raco test tests
```

## Run llama.cpp

```sh
llama-server -m /path/to/model.gguf --port 8080
```

## Use

```racket
#lang racket

(require rack-llm
         rack-llm/backends/llama-cpp)

(define model (make-llama-cpp-model))

(define g
  (grammar
   (system "Answer with one short sentence.")
   (user "Choose one: " (select "a" "b" "c"))
   (assistant (gen 20))))

(define g* (eval model g))

(grammar->messages g*)
```

`grammar` and `chat` both build a top-level chat program from messages.
Messages are built with `system`, `user`, and `assistant`.

Message parts are strings, `(gen max-tokens)`, `(select variant ...)`, or
`(seq part ...)` for grouping several parts as one `select` variant.

`eval` returns the same grammar shape with generated/selected nodes reduced to
text. `grammar->messages` converts the reduced grammar to `chat-message`
structs.
