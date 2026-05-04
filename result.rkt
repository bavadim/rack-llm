#lang racket/base

(provide (struct-out candidate)
         (struct-out result)
         candidate-ref
         result-ref)

(struct candidate
  (text       ; String: visible text produced by this candidate run
   state      ; Internal state after generation
   captures   ; Hash[Symbol, Any]
   trace      ; Listof Any, newest-last
   attempt    ; Natural
   error)     ; #f or exn
  #:transparent)

(struct result
  (messages   ; Listof message hashes
   captures   ; Hash[Symbol, Any]
   text       ; Last assistant text, if any
   trace      ; Listof Any
   state)     ; Internal state
  #:transparent)

(define missing-sentinel (gensym 'missing))

(define (hash-ref/default h key maybe-default who)
  (define default
    (if (null? maybe-default)
        missing-sentinel
        (car maybe-default)))
  (define value (hash-ref h key missing-sentinel))
  (cond
    [(not (eq? value missing-sentinel)) value]
    [(not (eq? default missing-sentinel)) default]
    [else (error who "missing capture: ~a" key)]))

(define (candidate-ref cand key . maybe-default)
  (hash-ref/default (candidate-captures cand) key maybe-default 'candidate-ref))

(define (result-ref res key . maybe-default)
  (hash-ref/default (result-captures res) key maybe-default 'result-ref))
