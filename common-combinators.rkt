#lang typed/racket/base

(require typed/racket/stream)

(provide stream-append-lazy
         stream-pure
         stream-bind
         stream-foldM
         sum-map)

(: stream-append-lazy (All (A) (-> (Sequenceof A) (-> (Sequenceof A)) (Sequenceof A))))
(define (stream-append-lazy xs tail)
  (cond
    [(stream-empty? xs) (tail)]
    [else
     (stream-cons (stream-first xs)
                  (stream-append-lazy (stream-rest xs) tail))]))

(: stream-pure (All (A) (-> A (Sequenceof A))))
(define (stream-pure x)
  (stream x))

(: stream-bind (All (A B) (-> (-> A (Sequenceof B)) (Sequenceof A) (Sequenceof B))))
(define (stream-bind f xs)
  (cond
    [(stream-empty? xs) empty-stream]
    [else
     (stream-append-lazy (f (stream-first xs))
                         (lambda ()
                           (stream-bind f (stream-rest xs))))]))

(: stream-foldM (All (A B) (-> (-> B A (Sequenceof B)) B (Listof A) (Sequenceof B))))
(define (stream-foldM step init xs)
  (foldl (lambda ([x : A] [states : (Sequenceof B)])
           (stream-bind (lambda ([state : B]) (step state x)) states))
         (stream-pure init)
         xs))

(: sum-map (All (A) (-> (-> A Natural) (Listof A) Natural)))
(define (sum-map f xs)
  (foldl (lambda ([x : A] [acc : Natural]) (+ (f x) acc)) 0 xs))
