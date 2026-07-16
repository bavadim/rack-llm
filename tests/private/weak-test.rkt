#lang racket/base

(require json
         rackunit
         racket/file
         "../../private/guidance.rkt"
         "../../private/weak.rkt")

(define descriptors
  '(("root/control/rule[0]" prefer ere)
    ("root/control/rule[1]" prefer literal)
    ("root/control/rule[2]" avoid ere)
    ("root/control/rule[3]" avoid literal)))
(define schema (make-weak-schema descriptors "test-tokenizer" 'test-shape))

(define (observation fires [spec 'template-a])
  (make-weak-observation
   schema spec
   (for/list ([descriptor (in-list descriptors)] [fire? (in-list fires)] #:when fire?)
     (weak-match (car descriptor) (cadr descriptor) #t 0 1))))

(define (synthetic-observations count seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (parameterize ([current-pseudo-random-generator rng])
    (for/list ([i (in-range count)])
      (define good? (< (random) 0.55))
      (define probabilities
        (if good? '(0.85 0.72 0.18 0.25) '(0.20 0.28 0.82 0.70)))
      (observation (map (lambda (p) (< (random) p)) probabilities)
                   (list 'parameterized i)))))

(module+ test
  (test-case "observations aggregate signed labels and ignore pattern source in schema"
    (define left (observation '(#t #f #t #f) 'spec-a))
    (define right (observation '(#f #t #f #t) 'spec-b))
    (check-equal? (vector->list (weak-observation-labels left)) '(1 0 -1 0))
    (check-equal? (weak-observation-schema-fingerprint left)
                  (weak-observation-schema-fingerprint right))
    (check-not-equal? (weak-observation-spec-fingerprint left)
                      (weak-observation-spec-fingerprint right)))

  (test-case "constrained EM recovers oriented rule reliabilities"
    (define model (fit-weak-model (synthetic-observations 4000 91)))
    (define positive (weak-posterior model (observation '(#t #t #f #f))))
    (define negative (weak-posterior model (observation '(#f #f #t #t))))
    (check-true (> positive 0.8))
    (check-true (< negative 0.2))
    (check-equal? (hash-ref (weak-model-diagnostics model) 'active-rules) 4))

  (test-case "diagnostics expose strongly correlated non-duplicate rules"
    (define rng (make-pseudo-random-generator))
    (parameterize ([current-pseudo-random-generator rng]) (random-seed 404))
    (define observations
      (parameterize ([current-pseudo-random-generator rng])
        (for/list ([i (in-range 2500)])
          (define good? (< (random) 0.5))
          (define shared (< (random) (if good? 0.85 0.15)))
          (observation
           (list shared
                 (if (< (random) 0.02) (not shared) shared)
                 (< (random) (if good? 0.15 0.85))
                 (< (random) (if good? 0.25 0.75)))))))
    (define diagnostics (weak-model-diagnostics (fit-weak-model observations)))
    (check-true (> (hash-ref diagnostics 'high-correlation-warnings) 0))
    (check-true (> (hash-ref diagnostics 'effective-rank) 0)))

  (test-case "fit fails closed for duplicate or insufficient columns"
    (define too-small
      (for/list ([i (in-range 20)])
        (observation (list (even? i) (even? i) (odd? i) (odd? i)))))
    (check-exn #rx"duplicate rule columns" (lambda () (fit-weak-model too-small))))

  (test-case "weak model JSON round-trip preserves posterior and fingerprint"
    (define model (fit-weak-model (synthetic-observations 2000 19)))
    (define path (make-temporary-file "rack-llm-weak-~a.json"))
    (dynamic-wind
      void
      (lambda ()
        (save-weak-model model path)
        (define loaded (load-weak-model path))
        (check-equal? (weak-model-fingerprint loaded) (weak-model-fingerprint model))
        (check-= (weak-posterior loaded (observation '(#t #f #f #f)))
                 (weak-posterior model (observation '(#t #f #f #f))) 1e-12))
      (lambda () (when (file-exists? path) (delete-file path)))))

  (test-case "v2 weak models are rejected after accepting-parse semantics change"
    (define path (make-temporary-file "rack-llm-weak-v2-~a.json"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file
         path
         #:exists 'truncate
         (lambda (out)
           (write-json
            (hash 'format "rack-llm-weak-model"
                  'version 2
                  'model "independent-polarity-bernoulli"
                  'observation_semantics "match-or-zero-v1")
            out)))
        (check-exn #rx"unsupported weak-model format or version"
                   (lambda () (load-weak-model path))))
      (lambda () (when (file-exists? path) (delete-file path))))))
