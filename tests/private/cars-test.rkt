#lang racket/base

(require racket/list
         rackunit
         "../../main.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt")

(define vocab (vector " a" " b" "<eog>"))

(define tok
  (tokenizer
   #:vocab-size 3
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize
   (lambda (text)
     (cond [(string=? text "") '()]
           [(string=? text " a") '(0)]
           [(string=? text " b") '(1)]
           [else (error 'tokenize "unexpected text: ~s" text)]))
   #:detokenize
   (lambda (ids) (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))

(define start-count (box 0))
(define end-count (box 0))

(define p
  (provider
   #:vocab-size 3
   #:eog-token-ids '(2)
   #:start-session
   (lambda (_prompt)
     (set-box! start-count (add1 (unbox start-count)))
     'session)
   #:next-logits/session
   (lambda (_session)
     (vector->logits-view (vector (log 0.6) (log 0.3) (log 0.1))))
   #:commit-token!
   (lambda (_session _id) (void))
   #:end-session!
   (lambda (_session) (set-box! end-count (add1 (unbox end-count))))))

(define m (model tok p (hash 'name 'tiny-cars) void))

(module+ test
  (test-case "weighted CARS samples the global Gibbs target and reuses its trie"
    (set-box! start-count 0)
    (set-box! end-count 0)
    (define program
      (choice (list (score (log 2.0) (lit " a"))
                    (lit " b"))))
    (define generator
      (make-generator m "" program
                      #:sampler (cars-sampler #:max-attempts 20)
                      #:beta 1.0
                      #:temperature 1.0
                      #:max-tokens 1
                      #:seed 17))
    (define results (generator-sample-n! generator 2000))
    (define a-count
      (count (lambda (result) (equal? (generation-result-token-ids result) '(0))) results))
    (check-true (andmap (lambda (result) (eq? (generation-result-status result) 'found)) results))
    ;; q(a)*2 : q(b) = 0.6*2 : 0.3 = 4 : 1.
    (check-= (/ a-count (length results)) 0.8 0.04)
    (define metrics (generation-result-metrics (last results)))
    (check-equal? (generation-metrics-sampler metrics) 'cars)
    (check-true (> (generation-metrics-trie-nodes metrics) 1))
    (check-= (generation-metrics-root-envelope metrics) 0.75 1e-9)
    (check-equal? (unbox start-count) (unbox end-count))
    (check-exn #rx"active generators" (lambda () (model-close! m)))
    (generator-close! generator))

  (test-case "weighted CARS rejects dynamic bind before opening a session"
    (define before (unbox start-count))
    (check-exn
     #rx"does not support bind"
     (lambda ()
       (make-generator
        m ""
        (bind (lit " a") (lambda (_value) (lit " b")))
        #:sampler (cars-sampler #:max-attempts 2)
        #:beta 1.0)))
    (check-equal? (unbox start-count) before))

  (test-case "attempt exhaustion returns no approximate fallback and closes sessions"
    (define before-start (unbox start-count))
    (define before-end (unbox end-count))
    (define result
      (generate m "" (choice '())
                #:sampler (cars-sampler #:max-attempts 1)
                #:beta 0.0
                #:max-tokens 1
                #:seed 3))
    (check-equal? (generation-result-status result) 'not-found-attempts)
    (check-equal? (generation-result-token-ids result) '())
    (check-equal? (- (unbox start-count) before-start) 1)
    (check-equal? (- (unbox end-count) before-end) 1)))
