#lang typed/racket/base/no-check

(require typed/rackunit
         "../support/logits.rkt")

(module+ test
  (test-case "function logits view behaves like vector logits view"
    (define values : (Vectorof Real) (vector 1.0 -2.0 3.5))
    (define vector-view (vector->logits-view values))
    (define function-view
      (function->logits-view
       (vector-length values)
       (lambda ([id : Natural])
         (vector-ref values id))))
    (check-equal? (logits-length function-view)
                  (logits-length vector-view))
    (check-equal? (logits-ref function-view 0)
                  (logits-ref vector-view 0))
    (check-equal? (logits-ref function-view 2)
                  (logits-ref vector-view 2))
    (check-equal? (logits->vector function-view)
                  (logits->vector vector-view))))
