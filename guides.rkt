#lang racket/base

(require "core.rkt")

(provide lit
         rx
         seq
         select
         repeat
         text
         rank
         ban)

(define (lit s)
  (unless (string? s)
    (raise-argument-error 'lit "string?" s))
  (guide 'lit s))

(define (rx pattern)
  (unless (or (regexp? pattern) (byte-regexp? pattern) (string? pattern))
    (raise-argument-error 'rx "regexp or string" pattern))
  (guide 'rx (if (string? pattern) (regexp pattern) pattern)))

(define (seq . guides)
  (guide 'seq (map (lambda (g) (ensure-guide 'seq g)) guides)))

(define (select . guides)
  (when (null? guides)
    (raise-arguments-error 'select "expected at least one choice"))
  (guide 'select (map (lambda (g) (ensure-guide 'select g)) guides)))

(define (repeat min-count max-count g)
  (unless (and (exact-nonnegative-integer? min-count)
               (exact-nonnegative-integer? max-count)
               (<= min-count max-count))
    (raise-arguments-error 'repeat
                           "expected 0 <= min <= max"
                           "min" min-count
                           "max" max-count))
  (guide 'repeat (list min-count max-count (ensure-guide 'repeat g))))

(define (text #:max-tokens [max-tokens 128] #:until [until #f] . watchers)
  (unless (exact-positive-integer? max-tokens)
    (raise-argument-error 'text "positive exact integer" max-tokens))
  (when (and until (not (or (guide? until) (string? until))))
    (raise-argument-error 'text "guide or string" until))
  (guide 'text (list max-tokens until (map (lambda (w) (ensure-watch 'text w))
                                           watchers))))

(define (rank score expr)
  (unless (real? score)
    (raise-argument-error 'rank "real?" score))
  (ranked score expr))

(define (ban expr)
  (banned expr))
