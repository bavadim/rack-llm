#lang typed/racket/base

(require racket/vector)

(provide LogitsView
         vector->logits-view
         logits-length
         logits-ref
         logits->vector
         check-logits-view)

(struct vector-logits-view ([values : (Vectorof Real)]) #:transparent)
(define-type LogitsView vector-logits-view)

(: vector->logits-view (-> (Vectorof Real) LogitsView))
(define (vector->logits-view values)
  (vector-logits-view values))

(: logits-length (-> LogitsView Natural))
(define (logits-length logits)
  (vector-length (vector-logits-view-values logits)))

(: logits-ref (-> LogitsView Natural Real))
(define (logits-ref logits id)
  (vector-ref (vector-logits-view-values logits) id))

(: logits->vector (-> LogitsView (Vectorof Real)))
(define (logits->vector logits)
  (vector-copy (vector-logits-view-values logits)))

(: check-logits-view (-> Symbol LogitsView Natural Void))
(define (check-logits-view who logits expected-size)
  (define actual-size (logits-length logits))
  (unless (= actual-size expected-size)
    (raise-arguments-error who
                           "logits length must match vocabulary"
                           "expected" expected-size
                           "actual" actual-size)))
