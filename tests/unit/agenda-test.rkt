#lang racket/base

(require rackunit
         rack-llm/sampling/agenda)

(define agenda-tests
  (test-suite
   "agenda"

   (test-case "list agenda pops highest priority first"
     (define a0 (agenda-empty 'list))
     (define a1 (agenda-push a0 (agenda-item 1.0 'a)))
     (define a2 (agenda-push a1 (agenda-item 3.0 'b)))
     (define-values (i a3) (agenda-pop-max a2))
     (check-equal? (agenda-item-payload i) 'b)
     (check-equal? (agenda-size a3) 1))

   (test-case "empty agenda reports empty and pop errors"
     (define a (agenda-empty 'list))
     (check-true (agenda-empty? a))
     (check-equal? (agenda-size a) 0)
     (check-exn #rx"empty agenda" (lambda () (agenda-pop-max a))))

   (test-case "ties use insertion order"
     (define a
       (agenda-push
        (agenda-push (agenda-empty 'list) (agenda-item 2.0 'first))
        (agenda-item 2.0 'second)))
     (define-values (i1 a1) (agenda-pop-max a))
     (define-values (i2 _a2) (agenda-pop-max a1))
     (check-equal? (agenda-item-payload i1) 'first)
     (check-equal? (agenda-item-payload i2) 'second))

   (test-case "unknown agenda kind fails clearly"
     (check-exn #rx"unsupported agenda kind"
                (lambda () (agenda-empty 'not-an-agenda))))

   (test-case "binary heap pops highest priority first"
     (define a
       (for/fold ([a (agenda-empty 'binary-heap)])
                 ([p (in-list '(5.0 1.0 3.0))])
         (agenda-push a (agenda-item p p))))
     (define-values (i1 a1) (agenda-pop-max a))
     (define-values (i2 a2) (agenda-pop-max a1))
     (check-equal? (agenda-item-priority i1) 5.0)
     (check-equal? (agenda-item-priority i2) 3.0)
     (check-equal? (agenda-size a2) 1))

   (test-case "binary heap ties use insertion order"
     (define a
       (agenda-push
        (agenda-push (agenda-empty 'binary-heap) (agenda-item 2.0 'first))
        (agenda-item 2.0 'second)))
     (define-values (i1 a1) (agenda-pop-max a))
     (define-values (i2 _a2) (agenda-pop-max a1))
     (check-equal? (agenda-item-payload i1) 'first)
     (check-equal? (agenda-item-payload i2) 'second))

   (test-case "pairing heap pops highest priority first"
     (define a
       (for/fold ([a (agenda-empty 'pairing-heap)])
                 ([p (in-list '(5.0 1.0 3.0))])
         (agenda-push a (agenda-item p p))))
     (define-values (i1 a1) (agenda-pop-max a))
     (define-values (i2 a2) (agenda-pop-max a1))
     (check-equal? (agenda-item-priority i1) 5.0)
     (check-equal? (agenda-item-priority i2) 3.0)
     (check-equal? (agenda-size a2) 1))

   (test-case "pairing heap ties use insertion order"
     (define a
       (agenda-push
        (agenda-push (agenda-empty 'pairing-heap) (agenda-item 2.0 'first))
        (agenda-item 2.0 'second)))
     (define-values (i1 a1) (agenda-pop-max a))
     (define-values (i2 _a2) (agenda-pop-max a1))
     (check-equal? (agenda-item-payload i1) 'first)
     (check-equal? (agenda-item-payload i2) 'second))

   (test-case "pairing heap matches binary heap pop order"
     (define priorities '(1.0 5.0 3.0 5.0 2.0 4.0))
     (check-equal? (pop-all 'pairing-heap priorities)
                   (pop-all 'binary-heap priorities)))

   (test-case "binary heap re-export module compiles"
     (dynamic-require 'rack-llm/sampling/binary-heap-agenda #f))))

(define (pop-all kind priorities)
  (let loop ([agenda (for/fold ([a (agenda-empty kind)])
                               ([p (in-list priorities)])
                       (agenda-push a (agenda-item p p)))]
             [acc '()])
    (cond
      [(agenda-empty? agenda) (reverse acc)]
      [else
       (define-values (item rest) (agenda-pop-max agenda))
       (loop rest (cons (agenda-item-priority item) acc))])))

(module+ test
  (require rackunit/text-ui)
  (run-tests agenda-tests))
