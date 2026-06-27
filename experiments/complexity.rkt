#lang racket/base

(require json
         racket/list
         racket/string)

(provide complexity-metric-keys
         (struct-out complexity-record)
         (struct-out complexity-summary)
         read-complexity-records
         read-complexity-records-from-file
         aggregate-complexity
         summarize-complexity
         complexity-csv-header
         complexity-summary->csv-row
         write-complexity-csv)

(define complexity-metric-keys
  '(expanded_nodes
    created_edges
    agenda_pushes
    agenda_pops
    max_frontier
    provider_calls
    grammar_checks
    yielded_candidates
    queue_time_ms
    provider_time_ms
    rules_time_ms))

(struct complexity-record
  (run-id
   method
   budget
   metrics)
  #:transparent)

(struct complexity-summary
  (run-id
   method
   budget
   count
   means
   stddevs)
  #:transparent)

(define (read-complexity-records in)
  (let loop ([records '()])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (reverse records)]
      [(string=? line "") (loop records)]
      [else
       (define maybe-record (jsexpr->complexity-record (string->jsexpr line)))
       (loop (if maybe-record
                 (cons maybe-record records)
                 records))])))

(define (read-complexity-records-from-file path)
  (call-with-input-file path read-complexity-records))

(define (aggregate-complexity records metric-key)
  (for/hash ([group (in-list (record-groups records))])
    (define metric-values
      (for/list ([record (in-list records)]
                 #:when (equal? group (record-group record)))
        (metric-value record metric-key)))
    (values group
            (hash 'count (length metric-values)
                  'mean (mean metric-values)
                  'std (stddev metric-values)))))

(define (summarize-complexity records)
  (for/list ([group (in-list (record-groups records))])
    (define group-records
      (filter (lambda (record) (equal? group (record-group record))) records))
    (complexity-summary
     (first group)
     (second group)
     (third group)
     (length group-records)
     (for/hash ([key (in-list complexity-metric-keys)])
       (values key (mean (map (lambda (record) (metric-value record key))
                              group-records))))
     (for/hash ([key (in-list complexity-metric-keys)])
       (values key (stddev (map (lambda (record) (metric-value record key))
                                group-records)))))))

(define (complexity-csv-header)
  (string-join
   (append '("run_id" "method" "budget" "count")
           (append-map (lambda (key)
                         (list (format "~a_mean" key)
                               (format "~a_std" key)))
                       complexity-metric-keys))
   ","))

(define (complexity-summary->csv-row summary)
  (string-join
   (append
    (list (csv-cell (complexity-summary-run-id summary))
          (csv-cell (complexity-summary-method summary))
          (csv-cell (complexity-summary-budget summary))
          (csv-cell (complexity-summary-count summary)))
    (append-map
     (lambda (key)
       (list (csv-cell (hash-ref (complexity-summary-means summary) key 0.0))
             (csv-cell (hash-ref (complexity-summary-stddevs summary) key 0.0))))
     complexity-metric-keys))
   ","))

(define (write-complexity-csv out summaries #:include-header? [include-header? #t])
  (when include-header?
    (displayln (complexity-csv-header) out))
  (for ([summary (in-list summaries)])
    (displayln (complexity-summary->csv-row summary) out)))

(define (jsexpr->complexity-record js)
  (define payload
    (cond
      [(and (hash? js) (hash-has-key? js 'payload)) (hash-ref js 'payload)]
      [else js]))
  (and (hash? payload)
       (payload-has-complexity? payload)
       (complexity-record
        (payload-string payload 'run_id "unknown")
        (payload-string payload
                        'method
                        (payload-string payload 'provider_mode "unknown"))
        (payload-natural payload 'budget (payload-natural payload 'rank 0))
        (payload-metrics payload))))

(define (payload-has-complexity? payload)
  (for/or ([key (in-list complexity-metric-keys)])
    (hash-has-key? payload key)))

(define (payload-metrics payload)
  (for/hash ([key (in-list complexity-metric-keys)])
    (values key (payload-number payload key 0.0))))

(define (payload-string payload key default)
  (define value (hash-ref payload key default))
  (cond
    [(string? value) value]
    [(symbol? value) (symbol->string value)]
    [else default]))

(define (payload-natural payload key default)
  (define value (hash-ref payload key default))
  (cond
    [(and (exact-nonnegative-integer? value) value) value]
    [(and (number? value) (>= value 0)) (inexact->exact (floor value))]
    [else default]))

(define (payload-number payload key default)
  (define value (hash-ref payload key default))
  (if (number? value)
      (exact->inexact value)
      default))

(define (record-group record)
  (list (complexity-record-run-id record)
        (complexity-record-method record)
        (complexity-record-budget record)))

(define (record-groups records)
  (sort (remove-duplicates (map record-group records)) group<?))

(define (group<? left right)
  (cond
    [(not (string=? (first left) (first right)))
     (string<? (first left) (first right))]
    [(not (string=? (second left) (second right)))
     (string<? (second left) (second right))]
    [else (< (third left) (third right))]))

(define (metric-value record metric-key)
  (hash-ref (complexity-record-metrics record) metric-key 0.0))

(define (mean values)
  (if (null? values)
      0.0
      (/ (apply + values) (length values))))

(define (stddev values)
  (cond
    [(null? values) 0.0]
    [else
     (define m (mean values))
     (sqrt (/ (for/sum ([value (in-list values)])
                (define delta (- value m))
                (* delta delta))
              (length values)))]))

(define (csv-cell value)
  (define s (format "~a" value))
  (if (regexp-match? #rx"[,\"\n]" s)
      (string-append "\""
                     (regexp-replace* #rx"\"" s "\"\"")
                     "\"")
      s))
