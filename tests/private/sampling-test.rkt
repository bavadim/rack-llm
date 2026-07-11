#lang typed/racket/base

(require typed/rackunit
         "../../private/logits.rkt"
         "../../private/sampling.rkt")

(module+ test
  (test-case "sample-scored-index is deterministic with equivalent rng state"
    (define logits : (Vectorof Real) (vector 0.0 1.0 -inf.0 2.0))
    (define rng-a (make-pseudo-random-generator))
    (define rng-b (make-pseudo-random-generator))
    (parameterize ([current-pseudo-random-generator rng-a]) (random-seed 18))
    (parameterize ([current-pseudo-random-generator rng-b]) (random-seed 18))
    (check-equal? (sample-scored-index logits rng-a 0.7)
                  (sample-scored-index logits rng-b 0.7)))

  (test-case "logits-log-z normalizes selected logit"
    (define logits : (Vectorof Real) (vector 0.0 1.0 -inf.0 2.0))
    (define log-z (logits-log-z (vector->logits-view logits)))
    (define expected (assert (log (+ (exp 0.0) (exp 1.0) (exp 2.0))) real?))
    (check-= log-z expected 1e-12)
    (check-= (logit-logprob 2.0 log-z) (- 2.0 expected) 1e-12)
    (check-equal? (logit-logprob -inf.0 log-z) -inf.0))

  (test-case "sample-scored-index ignores dead candidates"
    (define rng (make-rng 0))
    (define selected
      (sample-scored-index (vector -inf.0 -inf.0 0.0 -inf.0) rng 0.7))
    (check-not-false selected)
    (check-equal? (scored-selection-index (assert selected values)) 2))

  (test-case "masked sampler scans logits once and samples only sorted ids"
    (define logits : (Vectorof Real) (vector 1000.0 1.0 1000.0 3.0))
    (define reads : (Boxof Natural) (box 0))
    (define logits-view
      (function->logits-view
       (vector-length logits)
       (lambda ([id : Natural])
         (set-box! reads (add1 (unbox reads)))
         (vector-ref logits id))))
    (define selected
      (sample-masked-logits logits-view '(1 3) (make-rng 0) 0.7))
    (check-not-false selected)
    (define selected* (assert selected values))
    (check-equal? (unbox reads) (vector-length logits))
    (check-true (and (member (token-sampling-selection-id selected*) '(1 3)) #t))
    (check-equal? (token-sampling-selection-candidate-count selected*) 2)
    (check-equal? (token-sampling-selection-dead-count selected*) 2)
    (check-= (token-sampling-selection-lm-logprob selected*)
             (logit-logprob
              (vector-ref logits (token-sampling-selection-id selected*))
              (logits-log-z (vector->logits-view logits)))
             1e-12))

  (test-case "streaming logits sampler reads each logit once and reports lm logprob"
    (define logits : (Vectorof Real) (vector 0.0 1.0 2.0 3.0))
    (define reads : (Boxof Natural) (box 0))
    (define logits-view
      (function->logits-view
       (vector-length logits)
       (lambda ([id : Natural])
         (set-box! reads (add1 (unbox reads)))
         (vector-ref logits id))))
    (define selected
      (sample-logits-with-deltas
       logits-view
       (make-rng 0)
       0.7
       1.0
       (lambda ([id : Natural])
         (if (= id 2) -inf.0 0.0))))
    (check-not-false selected)
    (define selected* (assert selected values))
    (check-equal? (unbox reads) (vector-length logits))
    (check-equal? (token-sampling-selection-dead-count selected*) 1)
    (check-equal? (token-sampling-selection-candidate-count selected*) 3)
    (check-= (token-sampling-selection-lm-logprob selected*)
             (logit-logprob
              (vector-ref logits (token-sampling-selection-id selected*))
              (logits-log-z (vector->logits-view logits)))
             1e-12)))
