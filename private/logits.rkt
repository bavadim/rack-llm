#lang typed/racket/base

(require racket/vector)

(provide LogitsView
         vector->logits-view
         function->logits-view
         logits-length
         logits-ref
         logits->vector
         check-logits-view)

(struct vector-logits-view ([values : (Vectorof Real)]) #:transparent)
(struct function-logits-view ([length : Natural]
                              [ref : (-> Natural Real)])
  #:transparent)
(define-type LogitsView (U vector-logits-view function-logits-view))

(: vector->logits-view (-> (Vectorof Real) LogitsView))
(define (vector->logits-view values)
  (vector-logits-view values))

(: function->logits-view (-> Natural (-> Natural Real) LogitsView))
(define (function->logits-view length ref)
  (function-logits-view length ref))

(: logits-length (-> LogitsView Natural))
(define (logits-length logits)
  (cond
    [(vector-logits-view? logits)
     (vector-length (vector-logits-view-values logits))]
    [else
     (function-logits-view-length logits)]))

(: logits-ref (-> LogitsView Natural Real))
(define (logits-ref logits id)
  (cond
    [(vector-logits-view? logits)
     (vector-ref (vector-logits-view-values logits) id)]
    [else
     ((function-logits-view-ref logits) id)]))

(: logits->vector (-> LogitsView (Vectorof Real)))
(define (logits->vector logits)
  (cond
    [(vector-logits-view? logits)
     (vector-copy (vector-logits-view-values logits))]
    [else
     (for/vector : (Vectorof Real) ([id : Natural (in-range (logits-length logits))])
       (logits-ref logits id))]))

(: check-logits-view (-> Symbol LogitsView Natural Void))
(define (check-logits-view who logits expected-size)
  (define actual-size (logits-length logits))
  (unless (= actual-size expected-size)
    (raise-arguments-error who
                           "logits length must match vocabulary"
                           "expected" expected-size
                           "actual" actual-size)))
