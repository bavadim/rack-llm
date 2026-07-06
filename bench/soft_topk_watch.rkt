#lang racket/base

(require racket/format
         rack-llm)

(define vocab-size 50000)

(define vocab
  (append '("base")
          (for/list ([i (in-range 1 vocab-size)])
            (format "watch~a" i))))

(define logits
  (for/vector ([i (in-range vocab-size)])
    (if (zero? i) 10.0 0.0)))

(define (elapsed-ms thunk)
  (define start (current-inexact-milliseconds))
  (define result (thunk))
  (values (- (current-inexact-milliseconds) start) result))

(displayln "k,watchers,elapsed_ms,candidate_count_total,status")
(for* ([k (in-list '(1 8 32 64))]
       [w (in-list '(0 1 8 32))])
  (define watchers
    (for/list ([i (in-range w)])
      (rank 1 (format "watch~a" (add1 i)))))
  (define p
    (make-mock-provider
     #:vocab vocab
     #:default-logits logits))
  (define-values (ms result)
    (elapsed-ms
     (lambda ()
       (generate p "" (keyword-apply text '(#:max-tokens) '(1) watchers)
                 #:candidate-policy `(top-k+watch ,k)
                 #:seed 1
                 #:max-tokens 1))))
  (printf "~a,~a,~a,~a,~a\n"
          k
          w
          (~r ms #:precision '(= 3))
          (hash-ref (generation-result-metrics result) 'candidate-count-total)
          (generation-result-status result)))
