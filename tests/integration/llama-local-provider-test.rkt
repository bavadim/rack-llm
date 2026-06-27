#lang racket/base

(require rackunit
         rack-llm/providers/llama-local-provider
         rack-llm/providers/provider-v2)

(define (softmax-sum logits)
  (define max-logit
    (for/fold ([best -inf.0])
              ([x (in-vector logits)])
      (max best x)))
  (if (eqv? max-logit -inf.0)
      0.0
      (let ([z (for/sum ([x (in-vector logits)])
                 (exp (- x max-logit)))])
        (for/sum ([x (in-vector logits)])
          (/ (exp (- x max-logit)) z)))))

(define llama-local-integration-tests
  (test-suite
   "llama local provider integration"

   (test-case "local GGUF sidecar returns deterministic full-vocab logits when configured"
     (define model-path (getenv "RACK_LLM_TEST_GGUF"))
     (define command (getenv "RACK_LLM_LLAMA_SIDECAR"))
     (cond
       [(not (and model-path command))
        (check-true #t "set RACK_LLM_TEST_GGUF and RACK_LLM_LLAMA_SIDECAR to run")]
       [else
        (define sidecar (make-llama-sidecar command))
        (dynamic-wind
          void
          (lambda ()
            (define p
              (make-llama-sidecar-provider
               #:model-path model-path
               #:seed 123
               #:process sidecar))
            (define r1
              ((provider-next-logits p) '() "" (provider-initial-state p)))
            (define r2
              ((provider-next-logits p) '() "" (provider-initial-state p)))
            (define logits1 (logits-result-logits r1))
            (define logits2 (logits-result-logits r2))
            (check-true (> (provider-info-vocab-size (provider-info p)) 0))
            (check-equal? (vector-length logits1)
                          (provider-info-vocab-size (provider-info p)))
            (check-equal? (vector-length logits2) (vector-length logits1))
            (check-= (softmax-sum logits1) 1.0 1e-8)
            (for ([x (in-vector logits1)]
                  [y (in-vector logits2)])
              (check-= x y 1e-8)))
          (lambda ()
            ((llama-sidecar-close sidecar))))]))))

(module+ test
  (require rackunit/text-ui)
  (run-tests llama-local-integration-tests))
