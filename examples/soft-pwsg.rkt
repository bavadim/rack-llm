#lang racket/base

(require racket/list
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
   (text 12)
   (prefer (lit "clear"))
   (prefer (lit "answer"))
   (avoid (lit "sorry"))
   (avoid (lit "unknown"))
   (ban (lit "private key"))))

(define calibration-corpus
  (append
   (make-list 80 " clear answer")
   (make-list 30 " clear")
   (make-list 25 " answer")
   (make-list 70 " sorry unknown")
   (make-list 20 " sorry")
   (make-list 18 " unknown")))

(define (run-example model)
  (define compiled (compile-spec model spec))
  (dynamic-wind
    void
    (lambda ()
      (define weak-model
        (fit-weak-model (observe-many compiled calibration-corpus)))
      (require-found
       'soft-pwsg
       (generate
        compiled
        "Give a short direct answer to: What is 2+2?"
        #:sampler (cars-sampler #:max-attempts 100
                                #:weak-model weak-model)
        #:temperature 0.7
        #:max-tokens 12
        #:seed 13
        #:deadline-ms 60000)))
    (lambda () (compiled-spec-close! compiled))))

(module+ main
  (define model-path
    (or (getenv "RACK_LLM_GGUF_MODEL")
        (error 'soft-pwsg "set RACK_LLM_GGUF_MODEL to a GGUF model")))
  (define model
    (llama-cpp-model #:model-path model-path
                     #:context-size 192
                     #:threads 1
                     #:gpu-layers -1))
  (dynamic-wind
    void
    (lambda ()
      (define result (run-example model))
      (define weak (generation-result-weak result))
      (printf "~s (posterior ~a, ~a)\n"
              (generation-result-text result)
              (and weak (weak-result-posterior weak))
              (generation-result-distribution-guarantee result)))
    (lambda () (model-close! model))))
