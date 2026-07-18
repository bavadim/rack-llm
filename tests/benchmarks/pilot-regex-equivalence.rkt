#lang racket/base

(require json
         racket/file
         racket/list
         racket/string
         "../../private/regex.rkt")

;; Optional, artifact-backed regression used when an old pilot is available.
;; Usage:
;;   racket tests/benchmarks/pilot-regex-equivalence.rkt \
;;     raw-candidates.jsonl input-specs.jsonl observations.jsonl [family]
(define args (vector->list (current-command-line-arguments)))
(unless (<= 3 (length args) 4)
  (raise-user-error
   'pilot-regex-equivalence
   "expected raw-candidates.jsonl input-specs.jsonl observations.jsonl [family]"))
(define family-filter (and (= (length args) 4) (list-ref args 3)))
(define (read-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (for/list ([line (in-lines in)] #:unless (string=? line ""))
        (string->jsexpr line)))))
(define (get row key [default #f]) (hash-ref row key default))

(define texts (make-hash))
(for ([row (in-list (read-jsonl (list-ref args 0)))])
  (when (and (get row 'candidate_id) (string? (get row 'text)))
    (hash-set! texts (get row 'candidate_id) (get row 'text))))
(define specs (make-hash))
(for ([row (in-list (read-jsonl (list-ref args 1)))])
  (when (or (not family-filter) (string=? family-filter (get row 'family)))
    (hash-set! specs (get row 'id) (get row 'weak_rules))))

(define machines (make-hash))
(define (rule-label rule text)
  (define pattern (get rule 'pattern))
  (define matcher
    (hash-ref! machines pattern
               (lambda () (make-text-regex (parse-ere-pattern pattern)))))
  (if (regex-text-match? matcher text)
      (if (string=? "positive" (get rule 'polarity)) 1 -1)
      0))

(define rows 0)
(define label-mismatches 0)
(define row-mismatches 0)
(define examples '())
(for ([observation (in-list (read-jsonl (list-ref args 2)))]
      #:when (and (string=? "observation" (get observation 'record_type ""))
                  (hash-has-key? specs (get observation 'prompt_id))))
  (set! rows (add1 rows))
  (define text (hash-ref texts (get observation 'candidate_id)))
  (define actual
    (for/list ([rule (in-list (hash-ref specs (get observation 'prompt_id)))])
      (rule-label rule text)))
  (define expected (get observation 'labels))
  (define differences
    (for/sum ([a (in-list actual)] [e (in-list expected)])
      (if (= a e) 0 1)))
  (set! label-mismatches (+ label-mismatches differences))
  (when (positive? differences)
    (set! row-mismatches (add1 row-mismatches))
    (when (< (length examples) 10)
      (set! examples
            (cons (hasheq 'candidate_id (get observation 'candidate_id)
                          'prompt_id (get observation 'prompt_id)
                          'expected expected
                          'actual actual)
                  examples)))))

(write-json
 (hasheq 'benchmark "pilot-regex-equivalence"
         'family (or family-filter 'null)
         'rows rows
         'row_mismatches row-mismatches
         'label_mismatches label-mismatches
         'examples (reverse examples)))
(newline)
(unless (zero? label-mismatches) (exit 1))
