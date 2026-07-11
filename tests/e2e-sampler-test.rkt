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
    (error 'e2e-sampler-test
           "native GGUF model is required: ~a; set RACK_LLM_GGUF_MODEL or download Qwen3.5-4B-Q4_K_M.gguf"
           gguf-path))
  (llama-cpp-model
   #:model-path gguf-path
   #:context-size 192
   #:threads 1
   #:gpu-layers -1))

(define preferred " patent")

(define qwen-free-support-reply-11-token-baseline-ms 498.7)
(define soft-full-vocab-free-generation-ratio-budget 3.0)

(define support-reply-prompt
  "Rewrite this draft into a customer-ready support reply: TODO refund {amount} [ticket]. Reply with the message only:")

(define support-reply-target
  " we will refund the duplicate invoice and email the ticket number")

(define routing-label-prompt
  "Write one concise support routing label for a billing issue. Reply with the label only:")

(define routing-label-target
  " duplicate invoice refund investigation queue")

(define preferred-token-count 1)

(define (ranked-patent-filter)
  (text
   preferred-token-count
   (list (rank 30.0 preferred))))

(define (generate-ranked-patent backend #:deadline-ms deadline-ms)
  (generate backend
            "Write one legal invention keyword:"
            (ranked-patent-filter)
            #:beta 10.0
            #:sampler (local-sampler #:lambda 10.0)
            #:max-tokens preferred-token-count
            #:seed 0
            #:deadline-ms deadline-ms))

(define support-reply-token-count 11)

(define (support-reply-filter)
  (text
   support-reply-token-count
   (list (rank 100.0 support-reply-target)
         (ban "TODO")
         (ban " TODO")
         (ban "TBD")
         (ban "{")
         (ban "["))))

(define experiment-shaped-support-token-count 24)

(define experiment-shaped-support-prompt
  "Rewrite this draft into a concise customer-ready support reply: TODO duplicate invoice refund {amount} [ticket]. Reply with the final message only:")

(define (experiment-shaped-support-filter)
  (text
   experiment-shaped-support-token-count
   (list
    (rank-rx -3.0 "(?i)\\b(as an ai|i cannot|i can't|unable to|sorry)\\b")
    (rank-rx -3.0 "(?i)\\b(todo|tbd|unknown|n/a)\\b")
    (rank-rx -2.0 "(?i)(private key|api[_ -]?key|secret token)")
    (rank-rx -2.0 "(?i)(thinking process|analyze the request|hidden reasoning|</?think>)")
    (rank-rx -2.0 "[{}\\[\\]]")
    (rank-rx 2.0 "(?i)\\brefund\\b")
    (rank-rx 2.0 "(?i)\\binvoice\\b")
    (rank-rx 1.5 "(?i)\\bticket\\b")
    (rank-rx 1.5 "(?i)\\bduplicate\\b")
    (rank-rx 1.0 "(?i)\\bemail\\b")
    (rank-rx 1.0 "(?i)\\b(customer|support|account|charge)\\b")
    (rank-rx 0.75 "(?is)[\\s\\S]{40,400}")
    (rank-rx 0.75 "(?:\\b[A-Za-z]{3,}\\b[\\s,.;:!?]*){10,}")
    (rank-rx 0.5 "(?s)[.!?]\\s*$")
    (rank-rx 0.5 "(?i)\\b(refund|invoice)\\b[\\s\\S]*(?i)\\b(ticket|email)\\b|(?i)\\b(ticket|email)\\b[\\s\\S]*(?i)\\b(refund|invoice)\\b"))))

(define regex-support-reply-token-count 2)

(define (regex-support-reply-filter)
  (text
   regex-support-reply-token-count
   (list (rank-rx 120.0 "(?i)\\brefund\\b")
         (ban-rx "(?i)\\b(todo|tbd|unknown|n/a)\\b")
         (ban-rx "(?i)(private key|api[_ -]?key|secret token)"))))

(define routing-label-token-count 5)

(define (routing-label-filter)
  (text
   routing-label-token-count
   (list (rank 200.0 routing-label-target))))

(define (warmup-provider! backend)
  (void
   (generate backend
             "Reply exactly ok:"
             (lit " ok")
             #:max-tokens 2
             #:seed 0)))

(define (contains-ci? text needle)
  (string-contains? (string-downcase text) needle))

(define (placeholder-like? text)
  (or (string-contains? text "TODO")
      (string-contains? text "TBD")
      (string-contains? text "{")
      (string-contains? text "[")))

(define (contains-all-ci? text needles)
  (andmap (lambda (needle) (contains-ci? text needle)) needles))

(define (candidate-counts result)
  (generation-metrics-candidate-count-per-step
   (generation-result-metrics result)))

(define (candidate-count-total result)
  (generation-metrics-candidate-count-total
   (generation-result-metrics result)))

(define (check-near-full-vocab-candidates result max-tokens)
  (define metrics (generation-result-metrics result))
  (define counts (generation-metrics-candidate-count-per-step metrics))
  (define vocab-size (generation-metrics-vocab-size metrics))
  (check-equal? (length counts) max-tokens)
  (for ([count (in-list counts)])
    (check-true (<= count vocab-size))
    (check-true
     (>= count (- vocab-size 1024))
     (format "expected near full-vocab candidate coverage, got ~a of ~a"
             count
             vocab-size)))
  (check-equal? (generation-metrics-candidate-count-total metrics)
                (apply + counts)))

(module+ test
  (define backend #f)
  (dynamic-wind
    (lambda () (set! backend (open-real-backend)))
    (lambda ()
      (test-case "soft exact generation finds a domain label from the full vocabulary"
        (define max-tokens routing-label-token-count)
        (define full
          (generate backend
                    routing-label-prompt
                    (routing-label-filter)
                    #:beta 10.0
                    #:sampler (local-sampler #:lambda 10.0)
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens
                    #:deadline-ms 30000))
        (define full-text (generation-result-text full))
        (define vocab-size
          (generation-metrics-vocab-size (generation-result-metrics full)))
        (check-equal? (generation-result-status full) 'found)
        (check-true
         (contains-all-ci? full-text '("duplicate" "invoice" "refund" "investigation"))
         (format "full-vocab label should include the routed billing terms, got ~s" full-text))
        (check-equal? (candidate-counts full)
                      (make-list max-tokens vocab-size))
        (check-equal? (candidate-count-total full)
                      (* max-tokens vocab-size)))

      (test-case "soft full-vocab support reply vetoes placeholders and stays close to free generation"
        (define max-tokens support-reply-token-count)
        (warmup-provider! backend)
        (define started (current-inexact-milliseconds))
        (define result
          (generate backend
                    support-reply-prompt
                    (support-reply-filter)
                    #:beta 10.0
                    #:sampler (local-sampler #:lambda 10.0)
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens))
        (define elapsed-ms (- (current-inexact-milliseconds) started))
        (define generated (generation-result-text result))
        (define latency-budget-ms
          (* soft-full-vocab-free-generation-ratio-budget
             qwen-free-support-reply-11-token-baseline-ms))
        (check-equal? (generation-result-status result) 'found)
        (check-true (generation-result-hard-ok? result))
        (check-true (contains-ci? generated "refund")
                    (format "support reply should mention refund, got ~s" generated))
        (check-true (contains-ci? generated "invoice")
                    (format "support reply should mention invoice, got ~s" generated))
        (check-true (contains-ci? generated "ticket")
                    (format "support reply should mention ticket, got ~s" generated))
        (check-false (placeholder-like? generated)
                     (format "support reply should not contain placeholders, got ~s" generated))
        (check-true (> (generation-result-guidance-score result) 0.0))
        (check-near-full-vocab-candidates result max-tokens)
        (check-true
         (<= elapsed-ms latency-budget-ms)
         (format "soft full-vocab support reply took ~a ms; budget is ~a ms based on ~ax free-generation baseline ~a ms"
                 elapsed-ms
                latency-budget-ms
                soft-full-vocab-free-generation-ratio-budget
                qwen-free-support-reply-11-token-baseline-ms)))

      (test-case "soft full-vocab experiment-shaped regex rules stay close to free generation"
        (define max-tokens experiment-shaped-support-token-count)
        (warmup-provider! backend)
        (define started (current-inexact-milliseconds))
        (define result
          (generate backend
                    experiment-shaped-support-prompt
                    (experiment-shaped-support-filter)
                    #:beta 10.0
                    #:sampler (local-sampler #:lambda 1.0)
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens
                    #:deadline-ms 30000))
        (define elapsed-ms (- (current-inexact-milliseconds) started))
        (define generated (generation-result-text result))
        (define latency-budget-ms
          (* soft-full-vocab-free-generation-ratio-budget
             qwen-free-support-reply-11-token-baseline-ms
             (/ max-tokens support-reply-token-count)))
        (check-equal? (generation-result-status result) 'found)
        (check-true (generation-result-hard-ok? result))
        (check-true (contains-ci? generated "refund")
                    (format "experiment-shaped support reply should mention refund, got ~s" generated))
        (check-true (contains-ci? generated "invoice")
                    (format "experiment-shaped support reply should mention invoice, got ~s" generated))
        (check-true (contains-ci? generated "ticket")
                    (format "experiment-shaped support reply should mention ticket, got ~s" generated))
        (check-false (placeholder-like? generated)
                     (format "experiment-shaped support reply should not contain placeholders, got ~s" generated))
        (check-false (contains-ci? generated "<think>")
                     (format "experiment-shaped support reply should not contain hidden reasoning tags, got ~s" generated))
        (check-true (> (generation-result-guidance-score result) 0.0))
        (check-near-full-vocab-candidates result max-tokens)
        (check-true
         (<= elapsed-ms latency-budget-ms)
         (format "experiment-shaped soft full-vocab support reply took ~a ms; budget is ~a ms based on ~ax free-generation baseline ~a ms scaled to ~a tokens"
                 elapsed-ms
                 latency-budget-ms
                 soft-full-vocab-free-generation-ratio-budget
                 qwen-free-support-reply-11-token-baseline-ms
                 max-tokens)))

      (test-case "soft regex observers reward support terms and veto placeholders"
        (define max-tokens regex-support-reply-token-count)
        (define result
          (generate backend
                    "A customer was double charged. Reply with one support action word, not TODO:"
                    (regex-support-reply-filter)
                    #:beta 10.0
                    #:sampler (local-sampler #:lambda 1.0)
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens
                    #:deadline-ms 30000))
        (define generated (generation-result-text result))
        (check-equal? (generation-result-status result) 'found)
        (check-true (contains-ci? generated "refund")
                    (format "regex observer should reward refund, got ~s" generated))
        (check-false (placeholder-like? generated)
                     (format "regex ban observer should veto placeholders, got ~s" generated))
        (check-true (> (generation-result-guidance-score result) 0.0))
        (check-near-full-vocab-candidates result max-tokens)))
    (lambda ()
      (when backend
        (model-close! backend)))))
