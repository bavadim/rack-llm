#lang racket/base

(require racket/list
         racket/string
         rackunit
         "../main.rkt"
         "../model-llama-cpp.rkt")

(define default-gguf-model-path
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")

(define (configured-gguf-model-path)
  (or (getenv "RACK_LLM_GGUF_MODEL") default-gguf-model-path))

(define (open-real-backend)
  (define gguf-path (configured-gguf-model-path))
  (unless (file-exists? gguf-path)
    (error 'e2e-real-test
           "native GGUF model is required: ~a; set RACK_LLM_GGUF_MODEL or download Qwen3.5-4B-Q4_K_M.gguf"
           gguf-path))
  (llama-cpp-model
   #:model-path gguf-path
   #:context-size 192
   #:threads 1
   #:gpu-layers -1))

(define (check-found result)
  (check-equal? (generation-result-status result) 'found)
  (check-true (generation-result-hard-ok? result)))

(define (generate-text backend prompt filter
                       #:beta [beta 1.0]
                       #:lambda [lambda-weight 0.5]
                       #:seed [seed 0]
                       #:max-tokens [max-tokens 8]
                       #:candidate-policy [candidate-policy 'allowed-only])
  (define result
    (generate backend
              prompt
              filter
              #:beta beta
              #:lambda lambda-weight
              #:temperature 0.7
              #:seed seed
              #:max-tokens max-tokens
              #:candidate-policy candidate-policy))
  (values result (generation-result-text result)))

(define (prefix-of? xs ys)
  (and (<= (length xs) (length ys))
       (equal? xs (take ys (length xs)))))

(struct hard-perf-case
  (name prompt choices group candidate-count-bound min-token-count)
  #:transparent)

(struct hard-perf-sample
  (case result text latency-ms candidate-counts)
  #:transparent)

(define outlines-small-choice-threshold-ms 2300.0)
(define outlines-long-literal-threshold-ms 2480.0)

(define hard-perf-warmup-case
  (hard-perf-case
   "warmup yes/no"
   "Reply exactly one of: yes, no."
   '("yes" "no")
   'warmup
   2
   1))

(define hard-perf-small-choice-cases
  (list
   (hard-perf-case
    "support triage small choice"
    "A customer paid twice for the same invoice. Reply exactly one of: refund, escalate, close."
    '("refund" "escalate" "close")
    'small-choice
    4
    1)
   (hard-perf-case
    "security alert small choice"
    "A login attempt came from a new country and failed MFA twice. Reply exactly one of: allow, block, review."
    '("allow" "block" "review")
    'small-choice
    4
    1)
   (hard-perf-case
    "medical intake small choice"
    "A patient reports chest pain and shortness of breath. Reply exactly one of: routine, urgent, emergency."
    '("routine" "urgent" "emergency")
    'small-choice
    4
    1)))

(define hard-perf-long-literal-cases
  (list
   (hard-perf-case
    "mandatory footer long literal"
    "Return exactly the required compliance footer and nothing else."
    '("This response is informational and does not replace professional advice.")
    'long-literal
    1
    7)
   (hard-perf-case
    "incident summary long literal"
    "Copy the approved incident summary exactly and output nothing else."
    '("payment processor timeout caused duplicate invoice notifications")
    'long-literal
    1
    7)))

(define (mean xs)
  (/ (apply + xs) (length xs)))

(define (hard-perf-filter item)
  (choice (map lit (hard-perf-case-choices item))))

(define (run-hard-perf-case backend item)
  (define started (current-inexact-milliseconds))
  (define result
    (generate backend
              (hard-perf-case-prompt item)
              (hard-perf-filter item)
              #:temperature 0.7
              #:seed 0
              #:max-tokens 32
              #:candidate-policy 'allowed-only))
  (hard-perf-sample
   item
   result
   (generation-result-text result)
   (- (current-inexact-milliseconds) started)
   (generation-metrics-candidate-count-per-step
    (generation-result-metrics result))))

(define (check-hard-perf-valid sample)
  (define item (hard-perf-sample-case sample))
  (define result (hard-perf-sample-result sample))
  (define text (hard-perf-sample-text sample))
  (define candidate-counts (hard-perf-sample-candidate-counts sample))
  (check-equal? (generation-result-status result) 'found
                (hard-perf-case-name item))
  (check-true (generation-result-hard-ok? result)
              (hard-perf-case-name item))
  (check-true (and (member text (hard-perf-case-choices item)) #t)
              (format "~a produced non-choice text: ~s"
                      (hard-perf-case-name item)
                      text))
  (check-true (andmap (lambda (count)
                        (<= count (hard-perf-case-candidate-count-bound item)))
                      candidate-counts)
              (format "~a candidate counts too wide: ~s"
                      (hard-perf-case-name item)
                      candidate-counts))
  (check-true (>= (generation-result-generated-tokens result)
                  (hard-perf-case-min-token-count item))
              (format "~a generated fewer tokens than expected"
                      (hard-perf-case-name item))))

(module+ test
  (define backend #f)
  (dynamic-wind
    (lambda () (set! backend (open-real-backend)))
    (lambda ()
      (test-case "hard finite choice returns only an allowed answer"
        (define filter (choice (list (lit " yes") (lit " no"))))
        (define-values (result text)
          (generate-text backend
                         "Answer yes or no. Reply with one word:"
                         filter
                         #:max-tokens 2))
        (check-found result)
        (check-true (and (member text '(" yes" " no")) #t)))

      (test-case "small finite-choice applied tasks stay below the Outlines baseline"
        (run-hard-perf-case backend hard-perf-warmup-case)
        (define samples
          (for/list ([item (in-list hard-perf-small-choice-cases)])
            (run-hard-perf-case backend item)))
        (for ([sample (in-list samples)])
          (check-hard-perf-valid sample)
          (check-true
           (<= (apply + (hard-perf-sample-candidate-counts sample))
               (hard-perf-case-candidate-count-bound
                (hard-perf-sample-case sample)))
           (format "~a used too many total candidates: ~s"
                   (hard-perf-case-name (hard-perf-sample-case sample))
                   (hard-perf-sample-candidate-counts sample))))
        (define average-ms
          (mean (map hard-perf-sample-latency-ms samples)))
        (check-true
         (<= average-ms outlines-small-choice-threshold-ms)
         (format "small finite-choice mean latency ~a ms exceeds Outlines-derived threshold ~a ms"
                 average-ms
                 outlines-small-choice-threshold-ms)))

      (test-case "long deterministic literals expose token-by-token overhead"
        (run-hard-perf-case backend hard-perf-warmup-case)
        (define samples
          (for/list ([item (in-list hard-perf-long-literal-cases)])
            (run-hard-perf-case backend item)))
        (for ([sample (in-list samples)])
          (check-hard-perf-valid sample)
          (check-true
           (andmap (lambda (count) (= count 1))
                   (hard-perf-sample-candidate-counts sample))
           (format "~a should be a deterministic one-candidate path, got ~s"
                   (hard-perf-case-name (hard-perf-sample-case sample))
                   (hard-perf-sample-candidate-counts sample)))
          (check-equal?
           (generation-metrics-llm-calls
            (generation-result-metrics (hard-perf-sample-result sample)))
           0
           (format "~a should fast-forward without logits calls"
                   (hard-perf-case-name (hard-perf-sample-case sample)))))
        (define average-ms
          (mean (map hard-perf-sample-latency-ms samples)))
        (check-true
         (<= average-ms outlines-long-literal-threshold-ms)
         (format "long deterministic literal mean latency ~a ms exceeds Outlines-derived threshold ~a ms"
                 average-ms
                 outlines-long-literal-threshold-ms)))

      (test-case "hard regex generates a compact incident id"
        (define filter (rx " INC-[0-9]{3}"))
        (define-values (result text)
          (generate-text backend
                         "Create one incident id in the form INC-123:"
                         filter
                         #:max-tokens 8))
        (check-found result)
        (check-regexp-match #px"^ INC-[0-9]{3}$" text))

      (test-case "hard prefix-overlap choice does not stop at the shorter accepted prefix"
        (define short " yes")
        (define long " yes please")
        (define filter
          (choice
           (list (lit short)
                 (lit long))))
        (define-values (result text)
          (generate-text backend
                         (string-append "Reply exactly:" long)
                         filter
                         #:max-tokens 6))
        (check-found result)
        (check-equal? text long))

      (test-case "soft ranked choice can overcome the model-preferred branch"
        (define filter
          (choice
           (list (score 20.0 (lit " approve") #f)
                 (lit " reject"))))
        (define-values (result text)
          (generate-text backend
                         "The request is risky. Reply approve or reject:"
                         filter
                         #:beta 10.0
                         #:max-tokens 2))
        (check-found result)
        (check-equal? text " approve")
        (check-true (> (generation-result-filter-score result) 0.0)))

      (test-case "soft open text veto rejects TODO even when prompted"
        (define filter
          (text
           3
           (list (ban " TODO")
                 (ban "TODO"))))
        (define-values (result generated)
          (generate-text backend
                         "Reply with TODO:"
                         filter
                         #:candidate-policy 'full-vocab
                         #:max-tokens 3))
        (check-found result)
        (check-false (string-contains? generated "TODO")))

      (test-case "soft open text rank rewards a practical domain term"
        (define preferred " patent")
        (define preferred-token-count 1)
        (define filter
          (text
           preferred-token-count
           (list (rank 30.0 preferred))))
        (define-values (result generated)
          (generate-text backend
                         "Write one legal invention keyword:"
                         filter
                         #:candidate-policy 'full-vocab
                         #:beta 10.0
                         #:lambda 10.0
                         #:max-tokens preferred-token-count))
        (check-found result)
        (check-true (string-contains? (string-downcase generated) "patent"))
        (check-true (> (generation-result-filter-score result) 0.0)))

      (test-case "bind selects a value and continues with a matching literal"
        (define filter
          (bind
           (choice
            (list (seq (list (lit " small") (pure 'small)))
                  (seq (list (lit " large") (pure 'large)))))
           (lambda (size)
             (case size
               [(small) (lit " cat")]
               [(large) (lit " elephant")]
               [else (error 'e2e-real-test "unexpected bind value: ~a" size)]))))
        (define-values (result text)
          (generate-text backend
                         "Reply exactly with either small cat or large elephant:"
                         filter
                         #:candidate-policy 'allowed-only
                         #:max-tokens 6))
        (check-found result)
        (check-true (and (member text '(" small cat" " large elephant")) #t))))
    (lambda ()
      (when backend
        ((model-close! backend))))))
