#lang racket/base

(require rackunit
         "../../main.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt")

(define pieces (vector " a" " b" " x" "<eog>"))
(define tokenizer*
  (tokenizer
   #:vocab-size 4
   #:token-ref (lambda (id) (vector-ref pieces id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define id (for/first ([piece (in-vector pieces)] [i (in-naturals)]
                                   #:when (string=? piece source)) i))
            (if id (list id) (error 'tokenize "unknown text ~s" source))]))
   #:detokenize (lambda (ids) (apply string-append (map (lambda (id) (vector-ref pieces id)) ids)))))
(define provider*
  (provider
   #:vocab-size 4 #:eog-token-ids '(3)
   #:start-session (lambda (_prompt) 'session)
   #:next-logits/session (lambda (_session) (vector->logits-view (vector 3.0 2.0 1.0 0.0)))
   #:commit-token! (lambda (_session _id) (void))
   #:end-session! (lambda (_session) (void))))
(define model* (model tokenizer* provider* (hash) void))

(module+ test
  (test-case "hard CARS returns only the finite hard language"
    (define result
      (generate model* "" (choice (list (lit " a") (lit " b")))
                #:sampler (cars-sampler #:max-attempts 20)
                #:temperature 1.0 #:max-tokens 1 #:seed 4))
    (check-equal? (generation-result-status result) 'found)
    (check-not-false (member (generation-result-text result) '(" a" " b")))
    (check-equal? (generation-result-distribution-guarantee result) 'exact-hard))

  (test-case "scoped literal ban removes an otherwise likely token"
    (define result
      (generate model* "" (control (text 1) (ban (lit " a")))
                #:sampler (cars-sampler #:max-attempts 20)
                #:temperature 1.0 #:max-tokens 1 #:seed 2))
    (check-equal? (generation-result-status result) 'found)
    (check-not-equal? (generation-result-text result) " a"))

  (test-case "observe uses original result token ids and stable schema"
    (define spec
      (control (text 1)
               (prefer (lit " a"))
               (avoid (ere "x$"))))
    (define result
      (generate model* "" spec #:sampler (cars-sampler #:max-attempts 10)
                #:temperature 1.0 #:max-tokens 1 #:seed 8))
    (define observation (observe model* spec result))
    (check-equal? (vector-length (weak-observation-labels observation)) 2)
    (check-equal? (vector->list (weak-observation-rule-paths observation))
                  '("root/control/rule[0]" "root/control/rule[1]"))))
