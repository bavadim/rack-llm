#lang racket/base

(require rack-llm
         rack-llm/model-llama-cpp)

(provide run-example)

(define (require-found who result)
  (unless (eq? (generation-result-status result) 'found)
    (error who "~a: ~a"
           (generation-result-status result)
           (or (generation-result-reason result) "no reason")))
  result)

(define (run-example model)
  (define compiled
    (compile-spec model (choice (list (lit " yes") (lit " no")))))
  (dynamic-wind
    void
    (lambda ()
      (require-found
       'hard-choice
       (generate compiled
                 "Reply with exactly yes or no:"
                 #:sampler (cars-sampler #:max-attempts 50)
                 #:temperature 0.7
                 #:max-tokens 2
                 #:seed 7
                 #:deadline-ms 30000)))
    (lambda () (compiled-spec-close! compiled))))

(module+ main
  (define model-path
    (or (getenv "RACK_LLM_GGUF_MODEL")
        (error 'hard-choice "set RACK_LLM_GGUF_MODEL to a GGUF model")))
  (define model
    (llama-cpp-model #:model-path model-path
                     #:context-size 192
                     #:threads 1
                     #:gpu-layers -1))
  (dynamic-wind
    void
    (lambda ()
      (define result (run-example model))
      (printf "~a ~s (~a)\n"
              (generation-result-status result)
              (generation-result-text result)
              (generation-result-distribution-guarantee result)))
    (lambda () (model-close! model))))
