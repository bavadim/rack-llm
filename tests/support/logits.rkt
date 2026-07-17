#lang typed/racket/base/no-check

(provide LogitsView vector->logits-view function->logits-view
         logits-length logits-ref logits->vector check-logits-view)

(struct vector-logits-view ([values : (Vectorof Real)]) #:transparent)
(struct function-logits-view ([length : Natural] [ref : (-> Natural Real)]) #:transparent)
(define-type LogitsView (U vector-logits-view function-logits-view))

(define (vector->logits-view values) (vector-logits-view values))
(define (function->logits-view length ref) (function-logits-view length ref))
(define (logits-length logits)
  (if (vector-logits-view? logits)
      (vector-length (vector-logits-view-values logits))
      (function-logits-view-length logits)))
(define (logits-ref logits id)
  (if (vector-logits-view? logits)
      (vector-ref (vector-logits-view-values logits) id)
      ((function-logits-view-ref logits) id)))
(define (logits->vector logits)
  (for/vector : (Vectorof Real) ([id : Natural (in-range (logits-length logits))])
    (logits-ref logits id)))
(define (check-logits-view who logits expected-size)
  (unless (= (logits-length logits) expected-size)
    (raise-arguments-error who "logits length must match vocabulary"
                           "expected" expected-size
                           "actual" (logits-length logits))))
