#lang typed/racket/base

(require "../grammar.rkt"
         "../providers/provider-v2.rkt")

(provide allowed-token?
         allowed-token-mask
         mask-logits
         normalize-masked-logits)

(: allowed-token? (-> Matcher MatcherState String Boolean))
(define (allowed-token? m state token)
  (matcher-viable? (matcher-advance m state token)))

(: allowed-token-mask (-> Matcher MatcherState (Vectorof String) (Vectorof Boolean)))
(define (allowed-token-mask m state vocab)
  (for/vector : (Vectorof Boolean) ([token (in-vector vocab)])
    (allowed-token? m state token)))

(: mask-logits (-> LogitVector (Vectorof Boolean) LogitVector))
(define (mask-logits logits mask)
  (unless (= (vector-length logits) (vector-length mask))
    (error 'mask-logits
           "logits length ~a does not match mask length ~a"
           (vector-length logits)
           (vector-length mask)))
  (for/vector : LogitVector ([logit (in-vector logits)]
                             [allowed? (in-vector mask)])
    (if allowed? logit -inf.0)))

(: normalize-masked-logits (-> LogitVector LogitVector))
(define (normalize-masked-logits logits)
  (define max-logit (vector-max-logit logits))
  (cond
    [(eqv? max-logit -inf.0)
     (for/vector : LogitVector ([ignored (in-vector logits)]) -inf.0)]
    [else
     (define z
       (for/fold ([acc : Flonum 0.0])
                 ([logit (in-vector logits)])
         (if (eqv? logit -inf.0)
             acc
             (+ acc (exp (- logit max-logit))))))
     (define log-z : Flonum
       (+ max-logit (real->double-flonum (real-part (log z)))))
     (for/vector : LogitVector ([logit (in-vector logits)])
       (if (eqv? logit -inf.0)
           -inf.0
           (real->double-flonum (- logit log-z))))]))

(: vector-max-logit (-> LogitVector Flonum))
(define (vector-max-logit logits)
  (for/fold ([best : Flonum -inf.0])
            ([x (in-vector logits)])
    (max best x)))
