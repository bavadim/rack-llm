#lang racket/base

(require json
         racket/file
         racket/string)

(provide generate-artifacts
         csv-has-column?)

(define paper-budgets '(1 2 4 8 16))

(define (generate-artifacts run-dir out-dir)
  (make-directory* out-dir)
  (define metrics-wrapper
    (call-with-input-file (build-path run-dir "metrics.json") read-json))
  (define config-hash (hash-ref metrics-wrapper 'config_hash "unknown"))
  (define metrics (hash-ref metrics-wrapper 'metrics metrics-wrapper))
  (write-main-results (build-path out-dir "main_results.csv") config-hash metrics)
  (write-calibration-metrics (build-path out-dir "calibration_metrics.csv")
                             config-hash
                             metrics)
  (write-cost-metrics (build-path out-dir "cost_metrics.csv") config-hash run-dir)
  (write-ablation-results (build-path out-dir "ablation_results.csv")
                          config-hash
                          metrics)
  (write-markdown-summary (build-path out-dir "summary.md") config-hash metrics)
  (void))

(define (csv-has-column? path column)
  (define header
    (call-with-input-file path
      (lambda (in)
        (read-line in 'any))))
  (and (string? header)
       (and (member column (string-split header ","))
            #t)))

(define (write-main-results path config-hash metrics)
  (define gold-columns
    (for/list ([budget (in-list paper-budgets)])
      (format "GoldSuccess@~a" budget)))
  (define oracle-columns
    (for/list ([budget (in-list paper-budgets)])
      (format "Oracle@~a" budget)))
  (define efficiency-columns
    (for/list ([budget (in-list paper-budgets)])
      (format "SelectionEfficiency@~a" budget)))
  (define header (append (list "config_hash")
                         gold-columns
                         oracle-columns
                         efficiency-columns))
  (define row
    (append (list config-hash)
            (repeat-metric metrics 'gold_success_at_b)
            (repeat-metric metrics 'oracle_at_b)
            (repeat-metric metrics 'selection_efficiency_at_b)))
  (write-csv path header row))

(define (write-calibration-metrics path config-hash metrics)
  (write-csv path
             '("config_hash" "Brier" "ECE" "AUROC" "ConstraintSuccess")
             (list config-hash
                   (metric-value metrics 'brier)
                   (metric-value metrics 'ece)
                   (metric-value metrics 'auroc)
                   (metric-value metrics 'constraint_success_at_b))))

(define (write-cost-metrics path config-hash run-dir)
  (define complexity-path (build-path run-dir "complexity.csv"))
  (define has-complexity? (file-exists? complexity-path))
  (write-csv path
             '("config_hash"
               "expanded_nodes"
               "created_edges"
               "max_frontier"
               "provider_calls"
               "grammar_checks"
               "queue_time_ms"
               "provider_time_ms"
               "rules_time_ms")
             (if has-complexity?
                 (cons config-hash (first-complexity-row complexity-path))
                 (list config-hash "" "" "" "" "" "" "" ""))))

(define (write-ablation-results path config-hash metrics)
  (write-csv path
             '("config_hash"
               "method"
               "budget"
               "GoldSuccess"
               "Oracle"
               "SelectionEfficiency")
             (list config-hash
                   "default"
                   "all"
                   (metric-value metrics 'gold_success_at_b)
                   (metric-value metrics 'oracle_at_b)
                   (metric-value metrics 'selection_efficiency_at_b))))

(define (write-markdown-summary path config-hash metrics)
  (call-with-output-file path
    (lambda (out)
      (displayln "# Weak-IFBench Summary" out)
      (newline out)
      (displayln (format "- Config hash: `~a`" config-hash) out)
      (displayln (format "- GoldSuccess: ~a"
                         (metric-value metrics 'gold_success_at_b))
                 out)
      (displayln (format "- Oracle: ~a" (metric-value metrics 'oracle_at_b)) out)
      (displayln (format "- SelectionEfficiency: ~a"
                         (metric-value metrics 'selection_efficiency_at_b))
                 out)
      (displayln (format "- Brier: ~a" (metric-value metrics 'brier)) out))
    #:exists 'replace))

(define (repeat-metric metrics key)
  (for/list ([_budget (in-list paper-budgets)])
    (metric-value metrics key)))

(define (metric-value metrics key)
  (define value (hash-ref metrics key ""))
  (cond
    [(eq? value 'null) ""]
    [else value]))

(define (first-complexity-row path)
  (call-with-input-file path
    (lambda (in)
      (read-line in 'any)
      (define line (read-line in 'any))
      (if (eof-object? line)
          '("" "" "" "" "" "" "" "")
          (drop-leading-group-columns (string-split line ","))))))

(define (drop-leading-group-columns cells)
  (cond
    [(>= (length cells) 20)
     (list (list-ref cells 4)
           (list-ref cells 6)
           (list-ref cells 8)
           (list-ref cells 10)
           (list-ref cells 12)
           (list-ref cells 14)
           (list-ref cells 16)
           (list-ref cells 18))]
    [else '("" "" "" "" "" "" "" "")]))

(define (write-csv path header row)
  (call-with-output-file path
    (lambda (out)
      (displayln (string-join (map csv-cell header) ",") out)
      (displayln (string-join (map csv-cell row) ",") out))
    #:exists 'replace))

(define (csv-cell value)
  (define s (format "~a" value))
  (if (regexp-match? #rx"[,\"\n]" s)
      (string-append "\""
                     (regexp-replace* #rx"\"" s "\"\"")
                     "\"")
      s))
