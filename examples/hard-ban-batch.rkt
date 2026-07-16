#lang racket/base

(require racket/list
         racket/string
         rack-llm
         rack-llm/model-llama-cpp)

(provide run-example)

(define (require-found who result)
  (unless (eq? (generation-result-status result) 'found)
    (error who "~a: ~a"
           (generation-result-status result)
           (or (generation-result-reason result) "no reason")))
  result)

(define spec
  (control
   (ere " status=(approved|rejected|TODO)")
   (ban (lit "TODO"))))

(define (run-example model)
  (define compiled (compile-spec model spec))
  (dynamic-wind
    void
    (lambda ()
      (define generator
        (make-generator
         compiled
         "Return one status: approved or rejected."
         #:sampler (cars-sampler #:max-attempts 100)
         #:temperature 0.7
         #:max-tokens 8
         #:seed 11))
      (dynamic-wind
        void
        (lambda ()
          (define results
            (map (lambda (result) (require-found 'hard-ban-batch result))
                 (generator-sample-n! generator 3 #:deadline-ms 30000)))
          (when (ormap (lambda (result)
                         (string-contains? (generation-result-text result) "TODO"))
                       results)
            (error 'hard-ban-batch "hard ban was violated"))
          results)
        (lambda () (generator-close! generator))))
    (lambda () (compiled-spec-close! compiled))))

(module+ main
  (define model-path
    (or (getenv "RACK_LLM_GGUF_MODEL")
        (error 'hard-ban-batch "set RACK_LLM_GGUF_MODEL to a GGUF model")))
  (define model
    (llama-cpp-model #:model-path model-path
                     #:context-size 192
                     #:threads 1
                     #:gpu-layers -1))
  (dynamic-wind
    void
    (lambda ()
      (for ([result (in-list (run-example model))])
        (printf "~s (~a)\n"
                (generation-result-text result)
                (generation-result-distribution-guarantee result))))
    (lambda () (model-close! model))))
