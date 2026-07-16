#lang racket/base

(require racket/list
         rackunit
         "../main.rkt"
         "../model-llama-cpp.rkt")

(define default-model
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define model-path (or (getenv "RACK_LLM_GGUF_MODEL") default-model))

(define (open-model)
  (unless (file-exists? model-path)
    (error 'e2e-real-test "real GGUF model is required: ~a" model-path))
  (llama-cpp-model #:model-path model-path #:context-size 192 #:threads 1 #:gpu-layers -1))

(module+ test
  (define backend (open-model))
  (dynamic-wind
    void
    (lambda ()
      (test-case "real llama session follows a finite exact hard language"
        (define compiled
          (compile-spec backend (choice (list (lit " yes") (lit " no")))))
        (define result
          (generate compiled "Reply with exactly yes or no:"
                    #:sampler (cars-sampler #:max-attempts 50)
                    #:temperature 0.7 #:max-tokens 2 #:seed 7
                    #:deadline-ms 30000))
        (check-equal? (generation-result-status result) 'found)
        (check-not-false (member (generation-result-text result) '(" yes" " no")))
        (check-equal? (generation-result-distribution-guarantee result) 'exact-hard)
        (compiled-spec-close! compiled))

      (test-case "real llama session runs terminal-only PWSG rules"
        (define spec
          (control (text 12)
                   (prefer (lit "clear"))
                   (prefer (lit "answer"))
                   (avoid (lit "sorry"))
                   (avoid (lit "unknown"))))
        (define compiled (compile-spec backend spec))
        (define clear-answer (observe compiled " clear answer"))
        (define clear-only (observe compiled " clear"))
        (define answer-only (observe compiled " answer"))
        (define bad-both (observe compiled " sorry unknown"))
        (define sorry-only (observe compiled " sorry"))
        (define unknown-only (observe compiled " unknown"))
        (define calibration
          (append (make-list 80 clear-answer)
                  (make-list 30 clear-only)
                  (make-list 25 answer-only)
                  (make-list 70 bad-both)
                  (make-list 20 sorry-only)
                  (make-list 18 unknown-only)))
        (define weak-model (fit-weak-model calibration))
        (define result
          (generate compiled "Give a short direct answer to: What is 2+2?"
                    #:sampler (cars-sampler #:max-attempts 50 #:weak-model weak-model)
                    #:temperature 0.7 #:max-tokens 12 #:seed 11
                    #:deadline-ms 60000))
        (check-equal? (generation-result-status result) 'found)
        (check-true (weak-result? (generation-result-weak result)))
        (check-equal? (generation-result-distribution-guarantee result) 'exact-pwsg)
        (check-true (> (generation-metrics-weak-evaluations
                        (generation-result-metrics result)) 0))
        (compiled-spec-close! compiled)))
    (lambda () (model-close! backend))))
