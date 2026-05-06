# rack-llm

`rack-llm` is a small Racket library for building structured LLM interactions
with grammar-constrained generation. It is aimed at the same class of problems
as Microsoft Guidance: describe the shape of the conversation in code, let the
model fill only the dynamic parts, and read the selected/generated values back
from the evaluated program.

The core is backend-agnostic. The included llama.cpp backend talks to an already
running llama.cpp HTTP server, sends `%llguidance` grammar, and validates the
returned text against the original AST in Racket.

## Installation

From this repository:

```bash
raco pkg install --auto
raco test tests/unit
```

The package currently depends only on Racket libraries. The llama.cpp backend
does not build llama.cpp and does not load native extensions.

## Quick Start

```racket
#lang racket

(require rack-llm
         rack-llm/backends/llama-cpp)

(define tone
  (select (lit "short") (lit "detailed")))

(define answer
  (gen 40))

(define model
  (make-llama-cpp-model
   #:server-url "http://localhost:8080"))

(define program
  (chat
   (system (lit "Answer accurately."))
   (user
    (lit "Use a ")
    tone
    (lit " answer. What is Racket?"))
   (assistant answer)))

(define result
  (eval model program))

(grammar->messages result)
(value result tone)
(value result answer)
```

`eval` walks the chat from top to bottom. Static messages are copied into the
transcript. When a message contains `select` or `gen`, the current transcript and
that message body are sent to the model backend. The backend must return the
same AST fragment reduced to concrete choices and generated text.

## Core Ideas

`rack-llm` programs are ordinary Racket values:

```text
chat    = message ...
message = role + part
part    = lit | seq | select | gen | generated | selected
```

Messages carry chat roles:

```racket
(system part ...)
(user part ...)
(assistant part ...)
```

The role is metadata for the transcript. It is not compiled as grammar. If a
message receives multiple parts, they are wrapped as `(seq part ...)`.

Parts describe the constrained output surface:

```racket
(lit string)                 ; exact text
(seq part ...)               ; concatenation
(select first rest ...)      ; non-empty choice
(gen max-tokens)             ; generated text placeholder
```

After evaluation, computed nodes are replaced by result nodes:

```text
gen    -> generated
select -> selected
```

The evaluated chat keeps the same message/container shape, but every message
body becomes renderable through `lit`, `seq`, `generated`, and `selected`.

## Reading Results

Keep references to dynamic nodes before evaluation:

```racket
(define format
  (select (lit "json") (lit "plain text")))

(define body
  (gen 80))

(define result
  (eval model
        (chat
         (user (lit "Return ")
               format
               (lit " for the current status."))
         (assistant body))))

(value result format) ; selected Part, for example (lit "json")
(value result body)   ; generated String
```

Use `grammar->messages` when you need the final transcript:

```racket
(grammar->messages result)
```

Calling `grammar->messages` on an unevaluated chat that still contains `gen` or
`select` raises an error. This is intentional: rendering requires concrete
values.

## Backend Contract

A backend is a `chat-model`:

```text
grammar-request -> evaluated part
```

The request contains:

```racket
(grammar-request-messages req) ; previous evaluated messages
(grammar-request-part req)     ; current dynamic part to complete
```

That shape keeps backend-specific work outside the core. A backend may compile
the part however it wants, but it must return the reduced AST fragment, not just
raw text.

For tests or custom integrations:

```racket
(define model
  (make-chat-model
   (lambda (req)
     (define part (grammar-request-part req))
     (cond
       [(gen-node? part)
        (generated-node part "hello")]
       [else
        (error 'example "unsupported part: ~e" part)]))
   #:name "example"))
```

## llama.cpp Backend

```racket
(require rack-llm/backends/llama-cpp)

(define model
  (make-llama-cpp-model
   #:server-url "http://localhost:8080"))
```

If `#:server-url` is omitted, the backend reads
`RACK_LLM_LLAMA_SERVER` and then falls back to `http://localhost:8080`.

The backend compiles one message body `part` to `%llguidance` Lark and adds
captures for computed nodes:

```text
gen    -> capture "gen:<rule>"
select -> capture "select:<rule>:<branch>"
```

It sends the grammar and rendered previous messages to llama.cpp `/completion`.
llama.cpp constrains generation and returns final text. The backend then matches
that text against the original part locally, validates that the whole output fits
the supported AST, and rebuilds the reduced AST.

## Running llama.cpp

Acceptance tests and real examples need:

1. `llama-server` built with `%llguidance` grammar support.
2. A GGUF model.
3. A running HTTP server.

On this machine llama.cpp is available under:

```bash
/home/vadim/opt/llama.cpp
/home/vadim/.local/bin/llama-server
```

Example with a small Qwen GGUF model:

```bash
mkdir -p models
wget -O models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf

llama-server \
  --model models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --host 127.0.0.1 \
  --port 8080
```

Then use:

```bash
export RACK_LLM_LLAMA_SERVER=http://127.0.0.1:8080
```

## Environment Automation

`raco` remains the Racket package and test runner. `make` is used only for
external Unix orchestration: cloning/building llama.cpp, downloading a GGUF
model, and managing a local test server.

Build llama.cpp with LLGuidance support:

```bash
make deps
```

Download the default small Qwen model:

```bash
make model
```

Do both:

```bash
make env
```

Run a foreground server for manual use:

```bash
make server
```

The main variables are overrideable:

```bash
make deps LLAMA_CPP_REF=master LLAMA_CPP_DIR=.deps/llama.cpp
make model RACK_LLM_MODEL=models/qwen2.5-0.5b-instruct-q4_k_m.gguf
make server RACK_LLM_MODEL=models/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

## Tests

The test layout separates fast unit tests from model-backed acceptance tests:

```text
tests/unit/          fast tests, no network, no model
tests/acceptance/    real llama.cpp HTTP server, no mocks
```

Run unit tests:

```bash
raco test tests/unit
# or
make test
```

Run the unit test target whenever Racket or shell sources change. On macOS this
uses `osascript` notifications; on Linux it uses `notify-send` when available.
`make env` installs `watchexec`; on Linux it also installs
`libnotify-bin`/`libnotify` for desktop notifications and may ask for your
`sudo` password. To skip notification dependencies, run
`RACK_LLM_INSTALL_NOTIFY_DEPS=0 make env`.

```bash
make watch
make watch WATCH_TARGET=ci
```

Run lint and architecture checks:

```bash
make lint
```

`make lint` compiles the package, checks useless `require`s, checks package
dependency declarations, and runs project-specific API/source-policy tests.

Run every test file. Acceptance tests are skipped unless explicitly enabled:

```bash
raco test tests
# or
make test-all
```

Run the normal pre-PR gate:

```bash
make ci
```

Run acceptance tests against a real server:

```bash
export RACK_LLM_ACCEPTANCE=1
export RACK_LLM_LLAMA_SERVER=http://127.0.0.1:8080
raco test tests/acceptance
# or
make test-acceptance RACK_LLM_LLAMA_SERVER=http://127.0.0.1:8080
```

The acceptance tests do not start llama.cpp and do not mock the backend. They
assume the server is already running with a model that supports constrained
completion through llama.cpp guidance grammar.

For a fully local acceptance run, let `make` start and stop a temporary
`llama-server`:

```bash
make test-acceptance-local
```
