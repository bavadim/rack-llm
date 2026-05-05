# rack-llm

`rack-llm` is a small Typed Racket core for building chat grammar ASTs and
evaluating them with a pluggable model backend.

The llama.cpp backend is pure Racket. It connects to an already running
llama.cpp HTTP server, sends `%llguidance` grammar, and post-matches the final
text locally.

## Install

From this repository:

```bash
raco pkg install --auto
raco test tests
```

## Grammar

The public AST has three levels:

```text
chat    = message ...
message = role + part
part    = lit | seq | select | gen | generated | selected
```

Messages define roles:

```racket
(system part ...)
(user part ...)
(assistant part ...)
```

The role is chat metadata. It is not itself compiled as grammar. The message
body is a `part`; if a message receives several parts, they are wrapped as
`(seq part ...)`.

Parts:

```racket
(lit string)                 ; exact text
(seq part ...)               ; concatenation
(select first rest ...)      ; non-empty choice
(gen max-tokens)             ; generated text placeholder
```

After `eval`, computed nodes are replaced by result nodes:

```text
gen    -> generated
select -> selected
```

The evaluated chat keeps the same message/container shape, but all message
bodies become renderable text through `lit`, `seq`, `generated`, and `selected`.

## Example

```racket
#lang racket

(require rack-llm)

(define answer (gen 20))

(define model
  (make-chat-model
   (lambda (req)
     (define part (grammar-request-part req))
     (cond
       [(gen-node? part) (generated-node part "hello")]
       [else (error 'example "unsupported part: ~e" part)]))))

(define c
  (chat
   (system (lit "Answer shortly."))
   (assistant answer)))

(define c* (eval model c))

(grammar->messages c*)
(value c* answer)
```

The model contract is deliberately structural:

```text
grammar-request -> evaluated part
```

That keeps backend-specific work out of the core. A backend may compile the
input `part` however it wants, but it must return the reduced AST fragment, not
just final text.

## llama.cpp Backend

```racket
(require rack-llm
         rack-llm/backends/llama-cpp)

(define model
  (make-llama-cpp-model
   #:server-url "http://localhost:8080"))
```

The Racket backend compiles one message body `part` to `%llguidance` Lark and
adds captures for computed nodes:

```text
gen    -> capture "gen:<rule>"
select -> capture "select:<rule>:<branch>"
```

It sends the grammar and rendered previous messages to llama.cpp `/completion`.
llama.cpp constrains generation and returns final text. The backend then matches
that text against the original `part` in Racket, validates that the whole output
fits the supported AST, and rebuilds the reduced AST.

The llama.cpp server is installed and started separately. This package does not
build llama.cpp and has no native extension.
