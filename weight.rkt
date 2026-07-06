#lang racket/base

(require racket/match
         racket/string
         "core.rkt")

(provide weight
         (struct-out weighted-observer)
         (struct-out weighted-rule))

(struct weighted-observer (rules prior iterations) #:transparent)
(struct weighted-rule (weight expr source-score pos-prob neg-prob) #:transparent)

(define (weight #:data data
                #:max-iter [max-iter 50]
                #:tol [tol 1e-4]
                #:smoothing [smoothing 1e-3]
                . watchers)
  (unless (and (list? data) (pair? data) (andmap string? data))
    (raise-argument-error 'weight "non-empty list of strings" data))
  (unless (exact-positive-integer? max-iter)
    (raise-argument-error 'weight "positive exact max-iter" max-iter))
  (unless (and (real? tol) (positive? tol))
    (raise-argument-error 'weight "positive real tol" tol))
  (unless (and (real? smoothing) (positive? smoothing))
    (raise-argument-error 'weight "positive smoothing" smoothing))
  (for ([w (in-list watchers)])
    (unless (ranked? w)
      (raise-argument-error 'weight "rank watcher" w)))
  (when (null? watchers)
    (raise-arguments-error 'weight "expected at least one ranked watcher"))
  (define features
    (for/list ([sample (in-list data)])
      (for/vector ([w (in-list watchers)])
        (monitor-match? (ranked-expr w) sample))))
  (define signs
    (for/vector ([w (in-list watchers)])
      (if (negative? (ranked-score w)) -1 1)))
  (define-values (prior pos-probs neg-probs iterations)
    (em-fit features signs max-iter tol smoothing))
  (define rules
    (for/list ([w (in-list watchers)] [i (in-naturals)])
      (define raw (safe-log-odds (vector-ref pos-probs i)
                                 (vector-ref neg-probs i)))
      (define oriented (* (vector-ref signs i) (abs raw)))
      (weighted-rule oriented
                     (ranked-expr w)
                     (ranked-score w)
                     (vector-ref pos-probs i)
                     (vector-ref neg-probs i))))
  (watch 'weighted (weighted-observer rules prior iterations)))

(define (em-fit features signs max-iter tol smoothing)
  (define n (length features))
  (define k (vector-length signs))
  (define pos-probs
    (for/vector ([sign (in-vector signs)])
      (if (negative? sign) 0.25 0.75)))
  (define neg-probs
    (for/vector ([sign (in-vector signs)])
      (if (negative? sign) 0.75 0.25)))
  (let loop ([iter 0] [prior 0.5] [pos pos-probs] [neg neg-probs])
    (cond
      [(>= iter max-iter) (values prior pos neg iter)]
      [else
       (define responsibilities
         (for/list ([xs (in-list features)])
           (posterior-positive prior pos neg xs)))
       (define pos-den (+ smoothing (apply + responsibilities)))
       (define neg-den (+ smoothing (apply + (map (lambda (r) (- 1.0 r)) responsibilities))))
       (define next-pos
         (for/vector ([j (in-range k)])
           (clamp-prob
            (/ (+ smoothing
                  (for/sum ([xs (in-list features)] [r (in-list responsibilities)])
                    (if (vector-ref xs j) r 0.0)))
               pos-den))))
       (define next-neg
         (for/vector ([j (in-range k)])
           (clamp-prob
            (/ (+ smoothing
                  (for/sum ([xs (in-list features)] [r (in-list responsibilities)])
                    (if (vector-ref xs j) (- 1.0 r) 0.0)))
               neg-den))))
       (define next-prior
         (clamp-prob (/ (+ smoothing (apply + responsibilities))
                        (+ (* 2 smoothing) n))))
       (if (< (abs (- next-prior prior)) tol)
           (values next-prior next-pos next-neg (add1 iter))
           (loop (add1 iter) next-prior next-pos next-neg))])))

(define (posterior-positive prior pos-probs neg-probs xs)
  (define log-pos
    (+ (log (clamp-prob prior))
       (feature-log-likelihood pos-probs xs)))
  (define log-neg
    (+ (log (clamp-prob (- 1.0 prior)))
       (feature-log-likelihood neg-probs xs)))
  (define m (max log-pos log-neg))
  (define p (exp (- log-pos m)))
  (define q (exp (- log-neg m)))
  (/ p (+ p q)))

(define (feature-log-likelihood probs xs)
  (for/sum ([p (in-vector probs)] [x (in-vector xs)])
    (if x
        (log (clamp-prob p))
        (log (clamp-prob (- 1.0 p))))))

(define (safe-log-odds pos-prob neg-prob)
  (log (/ (clamp-prob pos-prob) (clamp-prob neg-prob))))

(define (clamp-prob p)
  (min 0.999 (max 0.001 p)))

(define (monitor-match? expr sample)
  (cond
    [(string? expr) (string-contains? sample expr)]
    [(guide? expr)
     (match (guide-kind expr)
       ['lit (string-contains? sample (guide-data expr))]
       ['rx (regexp-match? (guide-data expr) sample)]
       [else (raise-argument-error 'weight "lit, rx, or string" expr)])]
    [else (raise-argument-error 'weight "lit, rx, or string" expr)]))
