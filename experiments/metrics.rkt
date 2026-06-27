#lang racket/base

(require json
         racket/list
         racket/string)

(provide (struct-out eval-record)
         gold-success-at-b
         oracle-at-b
         selection-efficiency-at-b
         constraint-success-at-b
         constraint-success-by-id
         brier-score
         ece-score
         auroc-score
         duplicate-rate
         avg-candidates
         avg-latency-ms
         provider-k
         truncated-mass-mean
         summarize-eval-records
         metrics->json
         metrics-csv-header
         metrics-csv-row
         write-metrics-json
         write-metrics-csv)

(struct eval-record
  (task-id
   budget
   selected-rank
   gold-success?
   oracle-success?
   constraint-gold
   eta
   accepted?
   duplicate-rate
   latency-ms
   provider-k
   truncated-mass)
  #:transparent)

(define scalar-metric-keys
  '(record_count
    gold_success_at_b
    oracle_at_b
    selection_efficiency_at_b
    constraint_success_at_b
    brier
    ece
    auroc
    duplicate_rate
    avg_candidates
    latency_ms
    provider_k
    truncated_mass_mean))

(define (gold-success-at-b records)
  (mean (map (lambda (record) (bool->score (eval-record-gold-success? record)))
             records)))

(define (oracle-at-b records)
  (mean (map (lambda (record) (bool->score (eval-record-oracle-success? record)))
             records)))

(define (selection-efficiency-at-b records)
  (define gold (gold-success-at-b records))
  (define oracle (oracle-at-b records))
  (if (or (nan-value? gold) (nan-value? oracle) (zero? oracle))
      +nan.0
      (/ gold oracle)))

(define (constraint-success-at-b records)
  (mean
   (for*/list ([record (in-list records)]
               [(_constraint-id ok?) (in-hash (eval-record-constraint-gold record))])
     (bool->score ok?))))

(define (constraint-success-by-id records)
  (define constraint-ids
    (sort
     (remove-duplicates
      (for*/list ([record (in-list records)]
                  [(constraint-id _ok?) (in-hash (eval-record-constraint-gold record))])
        constraint-id))
     symbol<?))
  (for/hash ([constraint-id (in-list constraint-ids)])
    (values constraint-id
            (mean
             (for/list ([record (in-list records)]
                        #:when (hash-has-key? (eval-record-constraint-gold record)
                                              constraint-id))
               (bool->score
                (hash-ref (eval-record-constraint-gold record) constraint-id)))))))

(define (brier-score records)
  (mean
   (for/list ([record (in-list records)])
     (define eta (clamp01 (eval-record-eta record)))
     (define target (bool->score (eval-record-gold-success? record)))
     (square (- eta target)))))

(define (ece-score records bins)
  (cond
    [(zero? bins) (error 'ece-score "bin count must be positive")]
    [(null? records) +nan.0]
    [else
     (define total (length records))
     (for/sum ([bin (in-range bins)])
       (define bin-records
         (filter (lambda (record) (= bin (eta-bin (eval-record-eta record) bins)))
                 records))
       (if (null? bin-records)
           0.0
           (* (/ (exact->inexact (length bin-records)) total)
              (abs (- (gold-success-at-b bin-records)
                      (mean (map (lambda (record) (clamp01 (eval-record-eta record)))
                                 bin-records)))))))]))

(define (auroc-score records)
  (define positives
    (filter eval-record-gold-success? records))
  (define negatives
    (filter (lambda (record) (not (eval-record-gold-success? record))) records))
  (cond
    [(or (null? positives) (null? negatives)) +nan.0]
    [else
     (define wins
       (for*/sum ([positive (in-list positives)]
                  [negative (in-list negatives)])
         (define pos-eta (clamp01 (eval-record-eta positive)))
         (define neg-eta (clamp01 (eval-record-eta negative)))
         (cond
           [(> pos-eta neg-eta) 1.0]
           [(= pos-eta neg-eta) 0.5]
           [else 0.0])))
     (/ wins (* (length positives) (length negatives)))]))

(define (duplicate-rate records)
  (mean (map eval-record-duplicate-rate records)))

(define (avg-candidates records)
  (mean (map (lambda (record) (exact->inexact (eval-record-budget record)))
             records)))

(define (avg-latency-ms records)
  (mean (map eval-record-latency-ms records)))

(define (provider-k records)
  (define values (filter number? (map eval-record-provider-k records)))
  (if (null? values) 'null (mean values)))

(define (truncated-mass-mean records)
  (define values (filter number? (map eval-record-truncated-mass records)))
  (if (null? values) 'null (mean values)))

(define (summarize-eval-records records #:ece-bins [ece-bins 10])
  (hash 'record_count (length records)
        'gold_success_at_b (gold-success-at-b records)
        'oracle_at_b (oracle-at-b records)
        'selection_efficiency_at_b (selection-efficiency-at-b records)
        'constraint_success_at_b (constraint-success-at-b records)
        'constraint_success_by_id (constraint-success-by-id records)
        'brier (brier-score records)
        'ece (ece-score records ece-bins)
        'auroc (auroc-score records)
        'duplicate_rate (duplicate-rate records)
        'avg_candidates (avg-candidates records)
        'latency_ms (avg-latency-ms records)
        'provider_k (provider-k records)
        'truncated_mass_mean (truncated-mass-mean records)))

(define (metrics->json metrics)
  (json-safe metrics))

(define (metrics-csv-header)
  (string-join (map symbol->string scalar-metric-keys) ","))

(define (metrics-csv-row metrics)
  (string-join
   (for/list ([key (in-list scalar-metric-keys)])
     (csv-cell (hash-ref metrics key 'null)))
   ","))

(define (write-metrics-json out metrics)
  (write-json (metrics->json metrics) out)
  (newline out))

(define (write-metrics-csv out metrics #:include-header? [include-header? #t])
  (when include-header?
    (displayln (metrics-csv-header) out))
  (displayln (metrics-csv-row metrics) out))

(define (mean values)
  (if (null? values)
      +nan.0
      (/ (apply + values) (length values))))

(define (bool->score value)
  (if value 1.0 0.0))

(define (square value)
  (* value value))

(define (clamp01 value)
  (define v (exact->inexact value))
  (cond
    [(nan-value? v) 0.5]
    [(< v 0.0) 0.0]
    [(> v 1.0) 1.0]
    [else v]))

(define (eta-bin eta bins)
  (min (sub1 bins)
       (inexact->exact (floor (* (clamp01 eta) bins)))))

(define (nan-value? value)
  (and (real? value) (not (= value value))))

(define (json-safe value)
  (cond
    [(nan-value? value) 'null]
    [(hash? value)
     (for/hash ([(key nested-value) (in-hash value)])
       (values key (json-safe nested-value)))]
    [(list? value) (map json-safe value)]
    [else value]))

(define (csv-cell value)
  (define s
    (cond
      [(eq? value 'null) ""]
      [(nan-value? value) "nan"]
      [else (format "~a" value)]))
  (if (regexp-match? #rx"[,\"\n]" s)
      (string-append "\""
                     (regexp-replace* #rx"\"" s "\"\"")
                     "\"")
      s))
