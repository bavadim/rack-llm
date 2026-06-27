#lang racket/base

(require racket/list
         rack-llm/rules/acceptance)

(provide (struct-out rule-correlation-report)
         analyze-rule-correlations
         rule-correlation-report->diagnostics
         rule-correlation-report->metrics)

(struct rule-correlation-report
  (agreement
   conflict
   warnings)
  #:transparent)

(struct pair-metric
  (key
   shared
   agreement
   conflict)
  #:transparent)

(define high-correlation-threshold 0.95)
(define min-shared-observations 2)

(define (analyze-rule-correlations observation-sets)
  (define decision-tables
    (map observation-set->decision-table observation-sets))
  (define metrics
    (for/list ([pair (in-list (rule-id-pairs (collect-rule-ids observation-sets)))])
      (define-values (shared agreements conflicts)
        (pair-counts decision-tables (car pair) (cdr pair)))
      (pair-metric pair
                   shared
                   (rate agreements shared)
                   (rate conflicts shared))))
  (rule-correlation-report
   (for/hash ([metric (in-list metrics)])
     (values (pair-metric-key metric) (pair-metric-agreement metric)))
   (for/hash ([metric (in-list metrics)])
     (values (pair-metric-key metric) (pair-metric-conflict metric)))
   (correlation-warnings metrics)))

(define (rule-correlation-report->diagnostics report)
  (rule-correlation-report-warnings report))

(define (rule-correlation-report->metrics report)
  (hash 'high_correlation_pairs (length (rule-correlation-report-warnings report))
        'rule_pair_count (hash-count (rule-correlation-report-agreement report))))

(define (observation-set->decision-table observations)
  (for/fold ([table (hash)])
            ([observation (in-list observations)])
    (define rule-id (rule-observation-rule-id observation))
    (if (hash-has-key? table rule-id)
        table
        (hash-set table rule-id (rule-observation-decision observation)))))

(define (collect-rule-ids observation-sets)
  (sort
   (remove-duplicates
    (for*/list ([observations (in-list observation-sets)]
                [observation (in-list observations)])
      (rule-observation-rule-id observation)))
   symbol<?))

(define (rule-id-pairs rule-ids)
  (cond
    [(null? rule-ids) '()]
    [else
     (append (map (lambda (right) (cons (car rule-ids) right))
                  (cdr rule-ids))
             (rule-id-pairs (cdr rule-ids)))]))

(define (pair-counts decision-tables left right)
  (for/fold ([shared 0]
             [agreements 0]
             [conflicts 0])
            ([table (in-list decision-tables)])
    (define left-decision (hash-ref table left #f))
    (define right-decision (hash-ref table right #f))
    (cond
      [(and left-decision right-decision)
       (values (add1 shared)
               (if (eq? left-decision right-decision)
                   (add1 agreements)
                   agreements)
               (if (opposing-hard-decisions? left-decision right-decision)
                   (add1 conflicts)
                   conflicts))]
      [else (values shared agreements conflicts)])))

(define (opposing-hard-decisions? left right)
  (or (and (eq? left 'accept) (eq? right 'reject))
      (and (eq? left 'reject) (eq? right 'accept))))

(define (rate numerator denominator)
  (if (zero? denominator)
      0.0
      (/ (exact->inexact numerator) denominator)))

(define (correlation-warnings metrics)
  (append
   (for/list ([metric (in-list metrics)]
              #:when (high-rate? (pair-metric-shared metric)
                                  (pair-metric-agreement metric)))
     (format "rules ~a and ~a have high agreement (~a over ~a shared observations)"
             (car (pair-metric-key metric))
             (cdr (pair-metric-key metric))
             (pair-metric-agreement metric)
             (pair-metric-shared metric)))
   (for/list ([metric (in-list metrics)]
              #:when (high-rate? (pair-metric-shared metric)
                                  (pair-metric-conflict metric)))
     (format "rules ~a and ~a have high conflict (~a over ~a shared observations)"
             (car (pair-metric-key metric))
             (cdr (pair-metric-key metric))
             (pair-metric-conflict metric)
             (pair-metric-shared metric)))))

(define (high-rate? shared value)
  (and (>= shared min-shared-observations)
       (>= value high-correlation-threshold)))
