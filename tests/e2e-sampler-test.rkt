#lang racket/base

(require racket/list
         rackunit
         "../main.rkt"
         "../private/logits.rkt"
         "../private/model.rkt")

(define vocab (vector " yes" " no" "<eog>"))
(define tok
  (tokenizer
   #:vocab-size 3
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize (lambda (text) (cond [(string=? text "") '()]
                                  [(string=? text " yes") '(0)]
                                  [(string=? text " no") '(1)]
                                  [else (error 'tokenize "unknown text")]))
   #:detokenize (lambda (ids) (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))
(define p
  (provider #:vocab-size 3 #:eog-token-ids '(2)
            #:start-session (lambda (_prompt) 'session)
            #:next-logits/session (lambda (_session) (vector->logits-view (vector 0.0 0.0 -1.0)))
            #:commit-token! (lambda (_session _id) (void))
            #:end-session! (lambda (_session) (void))))
(define m (model tok p (hash) void))

(module+ test
  (test-case "reusable exact generator produces independent samples"
    (define generator
      (make-generator m "" (choice (list (lit " yes") (lit " no")))
                      #:sampler (cars-sampler #:max-attempts 20)
                      #:temperature 1.0 #:max-tokens 1 #:seed 33))
    (define results (generator-sample-n! generator 100))
    (check-true (andmap (lambda (r) (eq? (generation-result-status r) 'found)) results))
    (check-not-false
     (andmap (lambda (r) (and (member (generation-result-text r) '(" yes" " no")) #t)) results))
    (check-true (> (generation-metrics-trie-nodes
                    (generation-result-metrics (last results))) 1))
    (generator-close! generator)
    (check-exn #rx"closed" (lambda () (generator-sample! generator)))))
