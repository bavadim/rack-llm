#lang racket/base

(require json
         racket/file
         racket/list
         racket/string
         rack-llm/experiments/config
         rack-llm/experiments/metrics
         rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/heuristics
         rack-llm/rules/acceptance
         rack-llm/rules/combinators
         rack-llm/rules/dawid-skene
         rack-llm/rules/rule)

(provide (struct-out experiment-split)
         (struct-out runner-config)
         make-split
         run-weak-ifbench
         parse-budgets)

(struct experiment-split
  (calibration
   dev
   test)
  #:transparent)

(struct runner-config
  (data
   provider
   model
   budgets
   seed
   out)
  #:transparent)

(define (make-split tasks seed)
  (define ids
    (sort (map ifbench-task-id tasks)
          (lambda (left right)
            (< (split-key left seed) (split-key right seed)))))
  (define n (length ids))
  (define calibration-count (quotient n 3))
  (define dev-count (quotient (- n calibration-count) 2))
  (define-values (calibration rest) (split-at/list ids calibration-count))
  (define-values (dev test) (split-at/list rest dev-count))
  (experiment-split calibration dev test))

(define (run-weak-ifbench config)
  (define tasks (load-ifbench-jsonl (runner-config-data config)))
  (define split (make-split tasks (runner-config-seed config)))
  (define out-dir (runner-config-out config))
  (prepare-output-dirs out-dir)
  (write-json-file (build-path out-dir "split.json") (split->json split))
  (define frozen-config (runner->experiment-config config tasks split))
  (define config-hash (experiment-config-hash frozen-config))
  (write-experiment-config frozen-config (build-path out-dir "experiment-config.json"))
  (write-json-file (build-path out-dir "run.json") (config->json config config-hash))
  (write-split-task-files out-dir split)
  (define calibration-observations
    (calibration-observation-sets tasks split))
  (define ds-model
    (and (not (null? calibration-observations))
         (fit-dawid-skene default-ds-config calibration-observations)))
  (write-json-file (build-path out-dir "models" "ds-model.json")
                   (if ds-model (ds-model->json ds-model) 'null))
  (define thresholds (tune-thresholds-on-dev tasks split))
  (write-json-file (build-path out-dir "models" "thresholds.json") thresholds)
  (define records (test-eval-records tasks split (runner-config-budgets config)))
  (call-with-output-file (build-path out-dir "metrics.csv")
    (lambda (out)
      (write-run-metrics-csv out (summarize-eval-records records) config-hash))
    #:exists 'replace)
  (write-json-file (build-path out-dir "metrics.json")
                   (hash 'config_hash config-hash
                         'metrics (metrics->json (summarize-eval-records records))))
  (write-json-file (build-path out-dir "leakage-boundary.json")
                   (hash 'calibration "weak observations only; gold verifier not used"
                         'dev "gold verifier allowed for threshold tuning"
                         'test "gold verifier used only after selection for final evaluation"))
  split)

(define (parse-budgets text)
  (define budgets
    (for/list ([piece (in-list (string-split text ","))])
      (define maybe-number (string->number (string-trim piece)))
      (unless (and (exact-positive-integer? maybe-number))
        (error 'parse-budgets "expected positive integer budget: ~a" piece))
      maybe-number))
  (unless (not (null? budgets))
    (error 'parse-budgets "expected at least one budget"))
  budgets)

(define (calibration-observation-sets tasks split)
  (for/list ([task (in-list tasks)]
             #:when (member (ifbench-task-id task)
                            (experiment-split-calibration split)))
    (acceptance-report-observations
     (run-rules (acceptance-input (task-candidate task)
                                  (weak-rules-for-task task))))))

(define (tune-thresholds-on-dev tasks split)
  (define dev-count (length (experiment-split-dev split)))
  (define dev-gold-count
    (for/sum ([task (in-list tasks)]
              #:when (member (ifbench-task-id task)
                             (experiment-split-dev split)))
      (if (gold-verdict-prompt-passed?
           (run-gold-verifier task (task-candidate task)))
          1
          0)))
  (hash 'mode "all-constraints"
        'default_threshold 0.5
        'constraint_thresholds (hash)
        'dev_tasks dev-count
        'dev_gold_successes dev-gold-count))

(define (test-eval-records tasks split budgets)
  (for*/list ([budget (in-list budgets)]
              [task (in-list tasks)]
              #:when (member (ifbench-task-id task)
                             (experiment-split-test split)))
    (define candidate (task-candidate task))
    (define verdict (run-gold-verifier task candidate))
    (define passed? (gold-verdict-prompt-passed? verdict))
    (eval-record (ifbench-task-id task)
                 budget
                 (and passed? 1)
                 passed?
                 passed?
                 (gold-verdict-constraint-results verdict)
                 (if passed? 1.0 0.0)
                 passed?
                 0.0
                 0.0
                 #f
                 #f)))

(define (task-candidate task)
  (define candidate (hash-ref (ifbench-task-metadata task) 'candidate #f))
  (if (string? candidate) candidate (ifbench-task-prompt task)))

(define (prepare-output-dirs out-dir)
  (for ([dir (in-list (list out-dir
                            (build-path out-dir "calibration")
                            (build-path out-dir "dev")
                            (build-path out-dir "test")
                            (build-path out-dir "models")))])
    (make-directory* dir)))

(define (write-split-task-files out-dir split)
  (write-lines-file (build-path out-dir "calibration" "task-ids.txt")
                    (experiment-split-calibration split))
  (write-lines-file (build-path out-dir "dev" "task-ids.txt")
                    (experiment-split-dev split))
  (write-lines-file (build-path out-dir "test" "task-ids.txt")
                    (experiment-split-test split)))

(define (write-lines-file path lines)
  (call-with-output-file path
    (lambda (out)
      (for ([line (in-list lines)])
        (displayln line out)))
    #:exists 'replace))

(define (write-json-file path value)
  (call-with-output-file path
    (lambda (out)
      (write-json (json-key-safe value) out)
      (newline out))
    #:exists 'replace))

(define (json-key-safe value)
  (cond
    [(hash? value)
     (for/hash ([(key nested-value) (in-hash value)])
       (values (json-key-safe-key key) (json-key-safe nested-value)))]
    [(list? value) (map json-key-safe value)]
    [else value]))

(define (json-key-safe-key key)
  (cond
    [(symbol? key) key]
    [(string? key) (string->symbol key)]
    [else key]))

(define (split->json split)
  (hash 'calibration (experiment-split-calibration split)
        'dev (experiment-split-dev split)
        'test (experiment-split-test split)))

(define (config->json config config-hash)
  (hash 'data (path-string->string (runner-config-data config))
        'provider (symbol->string (runner-config-provider config))
        'model (runner-config-model config)
        'budgets (runner-config-budgets config)
        'seed (runner-config-seed config)
        'config_hash config-hash))

(define (runner->experiment-config config tasks split)
  (experiment-config
   (runner-config-provider config)
   (runner-config-model config)
   "weak-ifbench-local-candidate"
   "weak-ifbench-constraints"
   (weak-rule-id-strings tasks)
   (runner-config-budgets config)
   (runner-config-seed config)
   (split->json split)
   (hash 'data (path-string->string (runner-config-data config)))))

(define (path-string->string value)
  (cond
    [(path? value) (path->string value)]
    [else (format "~a" value)]))

(define (weak-rule-id-strings tasks)
  (sort
   (remove-duplicates
    (for*/list ([task (in-list tasks)]
                [wr (in-list (weak-rules-for-task task))])
      (symbol->string (rule-id (weighted-rule-rule wr)))))
   string<?))

(define (write-run-metrics-csv out metrics config-hash)
  (displayln (string-append "config_hash," (metrics-csv-header)) out)
  (displayln (string-append config-hash "," (metrics-csv-row metrics)) out))

(define (split-key id seed)
  (for/fold ([acc (modulo seed 2147483647)])
            ([ch (in-string id)])
    (modulo (+ (* 1103515245 acc) (char->integer ch) 12345)
            2147483647)))

(define (split-at/list xs n)
  (let loop ([remaining xs]
             [i n]
             [prefix '()])
    (cond
      [(or (zero? i) (null? remaining))
       (values (reverse prefix) remaining)]
      [else (loop (cdr remaining) (sub1 i) (cons (car remaining) prefix))])))

(module+ main
  (require racket/cmdline)

  (define data-path #f)
  (define provider 'mock)
  (define model "mock")
  (define budgets '(1))
  (define seed 42)
  (define out-dir #f)

  (command-line
   #:program "weak-ifbench-runner"
   #:once-each
   [("--data") path "Weak-IFBench JSONL path"
    (set! data-path path)]
   [("--provider") value "Provider id"
    (set! provider (string->symbol value))]
   [("--model") value "Model id or path"
    (set! model value)]
   [("--budgets") value "Comma-separated budgets, e.g. 1,2,4,8"
    (set! budgets (parse-budgets value))]
   [("--seed") value "Integer split seed"
    (define parsed (string->number value))
    (unless (integer? parsed)
      (error 'weak-ifbench-runner "seed must be an integer: ~a" value))
    (set! seed parsed)]
   [("--out") path "Output directory"
    (set! out-dir path)])

  (unless data-path
    (error 'weak-ifbench-runner "missing required --data"))
  (unless out-dir
    (error 'weak-ifbench-runner "missing required --out"))

  (run-weak-ifbench
   (runner-config data-path provider model budgets seed out-dir)))
