#lang racket/base

(require racket/format
         rack-llm)

(define (vec n hot-id)
  (for/vector ([i (in-range n)])
    (if (= i hot-id) 10.0 0.0)))

(define (make-vocab n)
  (for/list ([i (in-range n)])
    (if (zero? i) "ok" (format "junk~a" i))))

(define (elapsed-ms thunk)
  (define start (current-inexact-milliseconds))
  (define result (thunk))
  (values (- (current-inexact-milliseconds) start) result))

(displayln "vocab_size,elapsed_ms,candidate_count_total,runtime_step_calls,status")
(for ([n (in-list '(1000 5000 10000 50000))])
  (define p
    (make-mock-provider
     #:vocab (make-vocab n)
     #:default-logits (vec n 0)))
  (define-values (ms result)
    (elapsed-ms
     (lambda ()
       (generate p "" (text #:max-tokens 1)
                 #:candidate-policy 'full-vocab
                 #:seed 1
                 #:max-tokens 1))))
  (define metrics (generation-result-metrics result))
  (printf "~a,~a,~a,~a,~a\n"
          n
          (~r ms #:precision '(= 3))
          (hash-ref metrics 'candidate-count-total)
          (hash-ref metrics 'runtime-step-calls)
          (generation-result-status result)))
