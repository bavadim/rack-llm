# rack-llm

`rack-llm` is a small Racket library for writing LLM programs and reading a
lazy stream of valid results.

## Install

```bash
raco pkg install --auto
raco test tests/unit
```

For the bundled llama.cpp backend:

```bash
make env
make server
```

```racket
#lang racket

(require racket/stream
         racket/match
         (rename-in rack-llm [eval llm-eval])
         rack-llm/backends/llama-cpp)

(define complete
  (make-llama-cpp-llm #:server-url "http://127.0.0.1:8080"))
```

For OpenAI Responses API:

```racket
(require rack-llm/backends/openai-responses)

(define complete
  (make-openai-responses-llm
   #:model "gpt-5.4-nano"))
```

Use `message->string` to read an evaluated assistant message as a plain string.

## JSON

Task: choose a deployment decision.
Input: a short deployment report.
Output: a JSON string with `status` and `retry`.

```racket
(define decision
  (select (list (lit "{\"status\":\"ok\",\"retry\":false}"))
          (list (list (lit "{\"status\":\"warning\",\"retry\":true}"))
                (list (lit "{\"status\":\"error\",\"retry\":true}")))))

(define result
  (stream-first
   (llm-eval complete
             (list (user (lit "Deploy report: tests passed, latency is high. Return JSON."))
                   (assistant decision)))))

(message->string (last result))
```

## Repetition

`at-least-once` accepts a grammar and matches one or more repetitions of it.
The grammar may contain multiple expressions, including separators:

```racket
(define item
  (select (list (lit "\"red\""))
          (list (list (lit "\"blue\"")))))

(define tail
  (select
   '()
   (list
    (list
     (at-least-once
      (list (lit ", ") item))))))

(define result
  (stream-first
   (llm-eval complete
             (list
              (assistant (lit "[") item tail (lit "]"))))))

(message->string (last result))
```

The evaluated `repeated` value stores the matched text in `repeated-text`.

## Calculator

Task: solve a tiny arithmetic problem.
Input: `Use 2, 3, 4 with + and *`.
Output: a generated expression, evaluated by Racket code.

```racket
(define result
  (stream-first
   (llm-eval complete
             (list (user (lit "Generate one Racket expression using 2, 3, 4, +, *."))
                   (assistant (gen 12))))))

(define (calc x)
  (match x
    [(? number?) x]
    [`(+ ,a ,b) (+ (calc a) (calc b))]
    [`(* ,a ,b) (* (calc a) (calc b))]))

(calc (read (open-input-string (message->string (last result)))))
```

## Tic-Tac-Toe Search

Task: find a winning move for `X`.
Input board: `X X . / O O . / . . .`
Output: the accepted move index.

```racket
(define board '#("X" "X" "" "O" "O" "" "" "" ""))
(define wins '((0 1 2) (3 4 5) (6 7 8) (0 3 6) (1 4 7) (2 5 8) (0 4 8) (2 4 6)))
(define (win? i) (define b (vector-copy board)) (vector-set! b i "X")
  (for/or ([w wins]) (for/and ([j w]) (string=? "X" (vector-ref b j)))))

(define move
  (select (list (lit "0"))
          (map (lambda (i) (list (lit (number->string i)))) '(1 2 3 4 5 6 7 8))))

(define accepted
  (stream-filter
   (lambda (r) (win? (string->number (message->string (last r)))))
   (llm-eval complete
             (list (user (lit "Choose the winning tic-tac-toe move for X."))
                   (assistant move)))))

(message->string (last (stream-first accepted)))
```

`llm-eval` returns a lazy stream. Limits, filters, and stopping policy belong to
client code.
