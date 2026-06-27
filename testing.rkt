#lang racket/base

(require rackunit
         rack-llm/providers/mock-provider)

(provide make-deterministic-mock-provider
         check-stream-prefix)

(define make-deterministic-mock-provider make-mock-provider)

(define-check (check-stream-prefix actual expected)
  (define actual-prefix
    (for/list ([item actual]
               [_i (in-range (length expected))])
      item))
  (check-equal? actual-prefix expected))
