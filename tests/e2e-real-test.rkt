#lang racket/base

(require racket/list
         rackunit
         "../main.rkt")

(define default-model
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define model-path (or (getenv "RACK_LLM_GGUF_MODEL") default-model))

(define (open-model)
  (unless (file-exists? model-path)
    (error 'e2e-real-test "real GGUF model is required: ~a" model-path))
  (llama-cpp-backend #:model-path model-path #:cohort-width 4
                   #:context-per-lane 192 #:threads 1
                   #:batch-size 768 #:ubatch-size 192
                   #:batch-threads 4 #:gpu-layers -1))

(module+ test
  (define backend (open-model))
  (dynamic-wind
    void
    (lambda ()
      (test-case "real llama session follows a finite exact hard language"
        (define compiled
          (compile-spec backend (choice (lit " yes") (lit " no"))))
        (define result
          (car (generate-batch
                (list (generation-request
                       compiled "Reply with exactly yes or no:"
                       #:max-attempts 50
                       #:temperature 0.7 #:max-tokens 2 #:seed 7
                       #:deadline-ms 30000)))))
        (check-equal? (generation-result-status result) 'found)
        (check-not-false (member (generation-result-text result) '(" yes" " no"))))

      (test-case "real llama session runs terminal-only PWSG rules"
        (define spec
          (with-rules (text 12)
                      (positive (lit "clear"))
                      (positive (lit "answer"))
                      (negative (lit "sorry"))
                      (negative (lit "unknown"))))
        (define compiled (compile-spec backend spec))
        (define clear-answer '#(1 1 0 0))
        (define clear-only '#(1 0 0 0))
        (define answer-only '#(0 1 0 0))
        (define bad-both '#(0 0 -1 -1))
        (define sorry-only '#(0 0 -1 0))
        (define unknown-only '#(0 0 0 -1))
        (define calibration
          (append (make-list 80 clear-answer)
                  (make-list 30 clear-only)
                  (make-list 25 answer-only)
                  (make-list 70 bad-both)
                  (make-list 20 sorry-only)
                  (make-list 18 unknown-only)))
        (define weak-model
          (fit-weak-model calibration))
        (define result
          (car (generate-batch
                (list (generation-request
                       compiled "Give a short direct answer to: What is 2+2?"
                       #:max-attempts 50 #:weak-model weak-model
                       #:temperature 0.7 #:max-tokens 12 #:seed 11
                       #:deadline-ms 60000)))))
        (check-equal? (generation-result-status result) 'found)
        (check-true (real? (generation-result-posterior result))))

      (test-case "fixed cohort keeps four hard streams independent"
        (define compiled
          (compile-spec backend (choice (lit " yes") (lit " no"))))
        (define requests
          (for/list ([seed (in-range 4)])
            (generation-request
             compiled "Reply with exactly yes or no:"
             #:max-attempts 50
             #:temperature 0.7 #:max-tokens 2 #:seed seed
             #:deadline-ms 60000)))
        (define results (generate-batch requests))
        (for ([result (in-list results)])
          (check-equal? (generation-result-status result) 'found
                        (generation-result-reason result))
          (check-not-false (member (generation-result-text result) '(" yes" " no"))))))
    (lambda () (backend-close! backend))))
