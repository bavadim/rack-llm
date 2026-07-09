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

(define (generate-ranked-patent backend #:candidate-policy policy #:deadline-ms deadline-ms)
  (generate backend
            "Write one legal invention keyword:"
            (ranked-patent-filter)
            #:candidate-policy policy
            #:beta 10.0
            #:lambda 10.0
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
             #:candidate-policy 'allowed-only
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

(module+ test
  (define backend #f)
  (dynamic-wind
    (lambda () (set! backend (open-real-backend)))
    (lambda ()
      (test-case "sampler candidate policy metrics distinguish full vocab and top-k"
        (define full
          (generate-ranked-patent backend
                                  #:candidate-policy 'full-vocab
                                  #:deadline-ms 10000))
        (define top-k
          (generate-ranked-patent backend
                                  #:candidate-policy '(top-k 32)
                                  #:deadline-ms 10000))
        (check-equal? (generation-result-status full) 'found)
        (check-equal? (generation-result-status top-k) 'found)
        (check-equal? (generation-metrics-candidate-count-per-step
                       (generation-result-metrics full))
                      (list (generation-metrics-vocab-size
                             (generation-result-metrics full))))
        (check-equal? (generation-metrics-candidate-count-per-step
                       (generation-result-metrics top-k))
                      '(32))
        (check-equal? (generation-result-text full) preferred)
        (check-equal? (generation-result-text top-k) preferred))

      (test-case "soft full-vocab finds a domain label outside top-k"
        (define max-tokens routing-label-token-count)
        (define full
          (generate backend
                    routing-label-prompt
                    (routing-label-filter)
                    #:candidate-policy 'full-vocab
                    #:beta 10.0
                    #:lambda 10.0
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens
                    #:deadline-ms 30000))
        (define top-k
          (generate backend
                    routing-label-prompt
                    (routing-label-filter)
                    #:candidate-policy '(top-k 32)
                    #:beta 10.0
                    #:lambda 10.0
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens
                    #:deadline-ms 30000))
        (define full-text (generation-result-text full))
        (define top-k-text (generation-result-text top-k))
        (define vocab-size
          (generation-metrics-vocab-size (generation-result-metrics full)))
        (check-equal? (generation-result-status full) 'found)
        (check-equal? (generation-result-status top-k) 'found)
        (check-true
         (contains-all-ci? full-text '("duplicate" "invoice" "refund" "investigation"))
         (format "full-vocab label should include the routed billing terms, got ~s" full-text))
        (check-false
         (contains-all-ci? top-k-text '("duplicate" "invoice" "refund"))
         (format "top-k unexpectedly produced the full billing route: ~s" top-k-text))
        (check-equal? (candidate-counts full)
                      (make-list max-tokens vocab-size))
        (check-equal? (candidate-count-total full)
                      (* max-tokens vocab-size))
        (check-equal? (candidate-counts top-k)
                      (make-list max-tokens 32))
        (check-equal? (candidate-count-total top-k)
                      (* max-tokens 32)))

      (test-case "soft full-vocab support reply vetoes placeholders and stays close to free generation"
        (define max-tokens support-reply-token-count)
        (warmup-provider! backend)
        (define started (current-inexact-milliseconds))
        (define result
          (generate backend
                    support-reply-prompt
                    (support-reply-filter)
                    #:candidate-policy 'full-vocab
                    #:beta 10.0
                    #:lambda 10.0
                    #:temperature 0.7
                    #:seed 0
                    #:max-tokens max-tokens))
        (define elapsed-ms (- (current-inexact-milliseconds) started))
        (define generated (generation-result-text result))
        (define metrics (generation-result-metrics result))
        (define candidate-counts
          (generation-metrics-candidate-count-per-step metrics))
        (define vocab-size (generation-metrics-vocab-size metrics))
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
        (check-true (> (generation-result-filter-score result) 0.0))
        (check-equal? candidate-counts
                      (make-list max-tokens vocab-size))
        (check-equal? (generation-metrics-candidate-count-total metrics)
                      (* max-tokens vocab-size))
        (check-true
         (<= elapsed-ms latency-budget-ms)
         (format "soft full-vocab support reply took ~a ms; budget is ~a ms based on ~ax free-generation baseline ~a ms"
                 elapsed-ms
                 latency-budget-ms
                 soft-full-vocab-free-generation-ratio-budget
                 qwen-free-support-reply-11-token-baseline-ms))))
    (lambda ()
      (when backend
        ((model-close! backend))))))
