#lang racket/base

(require json
         racket/list
         racket/string
         "../../private/regex.rkt")

;; Reproduces the shape of the former word-count observation hotspot without a
;; model or experiment artifact.  This is an explicit benchmark, not a unit
;; test: callers can record wall time on their reference host without making
;; ordinary checks depend on scheduler load.
(define arguments (current-command-line-arguments))
(unless (<= (vector-length arguments) 2)
  (raise-user-error
   'weak-regex-benchmark
   "usage: weak-regex.rkt [candidate-count [max-elapsed-ms]]"))
(define candidate-count
  (if (zero? (vector-length arguments))
      480
      (string->number (vector-ref arguments 0))))
(unless (exact-positive-integer? candidate-count)
  (raise-user-error 'weak-regex-benchmark "candidate count must be a positive integer"))
(define max-elapsed-ms
  (if (< (vector-length arguments) 2)
      120000.0
      (string->number (vector-ref arguments 1))))
(unless (and (real? max-elapsed-ms) (positive? max-elapsed-ms))
  (raise-user-error 'weak-regex-benchmark "max elapsed ms must be positive"))

(define patterns
  ;; These are the five counted word patterns from one frozen v3 pilot spec.
  ;; In particular, the separator is `*`, not a repaired `+`: a multi-letter
  ;; token therefore has many possible repetition partitions and reproduces
  ;; the ambiguity which made the old backtracking-first observer stall.
  '("^[^A-Za-z0-9_]*([A-Za-z0-9_]+[^A-Za-z0-9_]*){33,69}$"
    "^[^A-Za-z0-9_]*([A-Za-z0-9_]+[^A-Za-z0-9_]*){40,}$"
    "^[^A-Za-z0-9_]*([A-Za-z0-9_]+[^A-Za-z0-9_]*){1,61}$"
    "^[^A-Za-z0-9_]*([A-Za-z0-9_]+[^A-Za-z0-9_]*){1,22}$"
    "^[^A-Za-z0-9_]*([A-Za-z0-9_]+[^A-Za-z0-9_]*){83,}$"))
(define candidates
  (for/list ([i (in-range candidate-count)])
    (string-join (make-list (+ 40 (modulo (* i 37) 180)) "token") " ")))

(collect-garbage)
(define started (current-inexact-milliseconds))
(define machines
  (for/list ([pattern (in-list patterns)])
    (make-text-regex (parse-ere-pattern pattern))))
(define matches
  (for*/sum ([candidate (in-list candidates)] [machine (in-list machines)])
    (if (regex-text-match? machine candidate) 1 0)))
(define elapsed (- (current-inexact-milliseconds) started))

(write-json
 (hasheq 'benchmark "weak-regex-word-count"
         'candidates candidate-count
         'patterns (length patterns)
         'matches matches
         'elapsed_ms elapsed
         'max_elapsed_ms max-elapsed-ms
         'matches_per_second
         (if (zero? elapsed) +inf.0 (/ (* candidate-count (length patterns) 1000.0) elapsed))))
(newline)
(when (> elapsed max-elapsed-ms)
  (eprintf "weak regex benchmark exceeded ~a ms: ~a ms\n" max-elapsed-ms elapsed)
  (exit 1))
