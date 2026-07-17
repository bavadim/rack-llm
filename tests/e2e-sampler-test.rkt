#lang racket/base

(require racket/list
         rackunit
         "../main.rkt"
         "../backend.rkt"
         "support/logits.rkt"
         "support/fake-cohort.rkt")

(define vocab (vector " yes" " no" "<eog>"))
(define tok
  (make-tokenizer
   #:vocab-size 3
   #:fingerprint "e2e-sampler-v1"
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize (lambda (text) (cond [(string=? text "") '()]
                                  [(string=? text " yes") '(0)]
                                  [(string=? text " no") '(1)]
                                  [else (error 'tokenize "unknown text")]))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))
(define p
  (make-fake-cohort-provider
   #:vocab-size 3 #:eog-token-ids '(2) #:cohort-width 8
   #:start-lane (lambda (_prompt) (box 0))
   #:logits/lane (lambda (_session)
                   (vector->logits-view (vector 0.0 0.0 -1.0)))
   #:commit-lane! (lambda (session _id) (set-box! session (add1 (unbox session))))))
(define m (make-backend tok p void))

(module+ test
  (test-case "tokenizer fingerprint is mandatory"
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-tokenizer #:vocab-size 1 #:token-ref values
                                 #:tokenize (lambda (_) '()) #:detokenize (lambda (_) "")))))
  (test-case "independent requests sample the exact finite language"
    (define compiled (compile-spec m (choice (lit " yes") (lit " no"))))
    (define requests
      (for/list ([seed (in-range 100)])
        (generation-request
         compiled "" #:max-attempts 20
         #:temperature 1.0 #:max-tokens 1 #:seed seed)))
    (define results (generate-batch requests))
    (check-true (andmap (lambda (r) (eq? (generation-result-status r) 'found)) results))
    (check-true
     (andmap (lambda (r)
               (and (member (generation-result-text r) '(" yes" " no")) #t))
             results))))
