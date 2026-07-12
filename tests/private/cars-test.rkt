#lang racket/base

(require racket/list
         rackunit
         "../../main.rkt"
         "../../private/guidance.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt"
         "../../private/weak.rkt")

(define vocab (vector " a" " b" " c" " d" "<eog>"))
(define tok
  (tokenizer
   #:vocab-size 5
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define found
              (for/first ([piece (in-vector vocab)] [id (in-naturals)]
                          #:when (string=? piece source)) id))
            (if found (list found) (error 'tokenize "unexpected text ~s" source))]))
   #:detokenize (lambda (ids) (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))

(define starts (box 0))
(define ends (box 0))
(define probabilities '(0.4 0.3 0.15 0.05 0.1))
(define provider*
  (provider
   #:vocab-size 5
   #:eog-token-ids '(4)
   #:start-session (lambda (_prompt) (set-box! starts (add1 (unbox starts))) 'session)
   #:next-logits/session
   (lambda (_session) (vector->logits-view (list->vector (map log probabilities))))
   #:commit-token! (lambda (_session _id) (void))
   #:end-session! (lambda (_session) (set-box! ends (add1 (unbox ends))))))
(define model* (model tok provider* (hash 'name 'tiny-pwsg) void))

(define spec
  (control
   (choice (map lit '(" a" " b" " c" " d")))
   (prefer (lit " a"))
   (prefer (lit " b"))
   (avoid (lit " c"))
   (avoid (lit " d"))))

(define descriptors
  '(("root/control/rule[0]" prefer literal)
    ("root/control/rule[1]" prefer literal)
    ("root/control/rule[2]" avoid literal)
    ("root/control/rule[3]" avoid literal)))

(define (synthetic-observation fires)
  (make-weak-observation
   descriptors 'parameterized-spec
   (for/list ([descriptor (in-list descriptors)] [fire? (in-list fires)] #:when fire?)
     (weak-match (car descriptor) (cadr descriptor) #t 0 1 '(0)))))

(define calibration
  (append
   (make-list 350 (synthetic-observation '(#t #t #f #f)))
   (make-list 120 (synthetic-observation '(#t #f #f #f)))
   (make-list 100 (synthetic-observation '(#f #t #f #f)))
   (make-list 300 (synthetic-observation '(#f #f #t #t)))
   (make-list 90 (synthetic-observation '(#f #f #t #f)))
   (make-list 80 (synthetic-observation '(#f #f #f #t)))))

(module+ test
  (test-case "PWSG CARS samples Q times posterior and reuses its fractional trie"
    (set-box! starts 0)
    (set-box! ends 0)
    (define weak-model (fit-weak-model calibration))
    (define qs
      (for/vector ([source (in-list '(" a" " b" " c" " d"))])
        (weak-posterior weak-model (observe model* spec source))))
    (define raw
      (for/vector ([base (in-list (take probabilities 4))] [q (in-vector qs)]) (* base q)))
    (define z (for/sum ([x (in-vector raw)]) x))
    (define expected (for/vector ([x (in-vector raw)]) (/ x z)))
    (define generator
      (make-generator model* "" spec
                      #:sampler (cars-sampler #:max-attempts 100 #:weak-model weak-model)
                      #:temperature 1.0 #:max-tokens 1 #:seed 17))
    (define results (generator-sample-n! generator 5000))
    (check-true (andmap (lambda (result) (eq? (generation-result-status result) 'found)) results))
    (for ([id (in-range 4)])
      (define observed
        (/ (count (lambda (result) (equal? (generation-result-token-ids result) (list id))) results)
           (length results)))
      (check-= observed (vector-ref expected id) 0.035))
    (define last-metrics (generation-result-metrics (last results)))
    (check-true (> (generation-metrics-trie-nodes last-metrics) 1))
    (check-true (> (generation-metrics-weak-cache-hits last-metrics) 0))
    (check-equal? (unbox starts) (unbox ends))
    (generator-close! generator))

  (test-case "schema mismatch and unsupported PWSG spec fail before sessions"
    (define weak-model (fit-weak-model calibration))
    (define before (unbox starts))
    (check-exn #rx"unsupported PWSG program"
               (lambda ()
                 (make-generator model* "" (rx " a")
                                 #:sampler (cars-sampler #:max-attempts 2
                                                        #:weak-model weak-model))))
    (check-exn #rx"incompatible weak model"
               (lambda ()
                 (make-generator model* "" (control (text 1) (prefer (lit " a")))
                                 #:sampler (cars-sampler #:max-attempts 2
                                                        #:weak-model weak-model))))
    (check-equal? (unbox starts) before))

  (test-case "attempt exhaustion returns no approximate fallback"
    (define result
      (generate model* "" (choice '())
                #:sampler (cars-sampler #:max-attempts 1)
                #:temperature 1.0 #:max-tokens 1 #:seed 3))
    (check-not-false (member (generation-result-status result)
                             '(not-found-attempt-budget not-found-support)))
    (check-false (generation-result-hard-ok? result))))
