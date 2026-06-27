#lang racket/base

(require rackunit
         rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene
         rack-llm/traces/trace)

(define (obs rule-id decision)
  (rule-observation rule-id decision #f (hash)))

(define (cobs constraint-id rule-id decision)
  (constraint-observation constraint-id (obs rule-id decision)))

(define (repeat n x)
  (if (zero? n) '() (cons x (repeat (sub1 n) x))))

(define synthetic-observations
  (append
   (repeat 80 (list (obs 'r1 'accept) (obs 'r2 'accept)))
   (repeat 15 (list (obs 'r1 'reject) (obs 'r2 'accept)))
   (repeat 80 (list (obs 'r1 'reject) (obs 'r2 'reject)))
   (repeat 15 (list (obs 'r1 'accept) (obs 'r2 'reject)))
   (repeat 10 (list (obs 'r1 'abstain) (obs 'r2 'abstain)))))

(define synthetic-constraint-observations
  (append
   (repeat 30 (list (cobs 'word-count 'r1 'accept)
                    (cobs 'phrase-presence 'r2 'accept)))
   (repeat 30 (list (cobs 'word-count 'r1 'reject)
                    (cobs 'phrase-presence 'r2 'reject)))
   (list (list (cobs 'rare 'r1 'accept)))))

(define dawid-skene-tests
  (test-suite
   "Dawid-Skene"

   (test-case "EM converges on synthetic noisy binary observations"
     (define model
       (fit-dawid-skene (ds-config 100 1e-7 1.0 0.5) synthetic-observations))
     (check-true (ds-model-converged? model))
     (check-true (> (estimated-accuracy model 'r1) 0.75))
     (check-true (> (ds-rule-outcome-prob model 'r1 0 'reject) 0.75)))

   (test-case "posterior stays within bounds and responds to evidence"
     (define model
       (fit-dawid-skene (ds-config 100 1e-7 1.0 0.5) synthetic-observations))
     (define good-p (ds-posterior model (list (obs 'r1 'accept) (obs 'r2 'accept))))
     (define bad-p (ds-posterior model (list (obs 'r1 'reject) (obs 'r2 'reject))))
     (check-true (<= 0.0 good-p 1.0))
     (check-true (<= 0.0 bad-p 1.0))
     (check-true (> good-p bad-p)))

   (test-case "model JSON round-trips"
     (define model
       (fit-dawid-skene (ds-config 20 1e-6 1.0 0.5) synthetic-observations))
     (check-equal? (json->ds-model (ds-model->json model)) model)
     (check-equal? (hash-ref (ds-model->json model) 'orientation)
                   (hash 'mode "manual" 'anchor_rule_id 'null 'good_class 1)))

   (test-case "manual orientation can restore a flipped model"
     (define model
       (fit-dawid-skene (ds-config 100 1e-7 1.0 0.5) synthetic-observations))
     (define good-obs (list (obs 'r1 'accept) (obs 'r2 'accept)))
     (define bad-obs (list (obs 'r1 'reject) (obs 'r2 'reject)))
     (define flipped (orient-ds-model model (ds-orientation 'manual #f 0) #f))
     (check-true (< (ds-posterior flipped good-obs)
                    (ds-posterior flipped bad-obs)))
     (define restored (orient-ds-model flipped (ds-orientation 'manual #f 0) #f))
     (check-true (> (ds-posterior restored good-obs)
                    (ds-posterior restored bad-obs))))

   (test-case "anchor and dev-gold orientation choose class correlated with good"
     (define model
       (fit-dawid-skene (ds-config 100 1e-7 1.0 0.5) synthetic-observations))
     (define flipped (orient-ds-model model (ds-orientation 'manual #f 0) #f))
     (define good-obs (list (obs 'r1 'accept) (obs 'r2 'accept)))
     (define bad-obs (list (obs 'r1 'reject) (obs 'r2 'reject)))
     (define anchored (orient-ds-model flipped (ds-orientation 'anchor-rule 'r1 1) #f))
     (check-true (> (ds-posterior anchored good-obs)
                    (ds-posterior anchored bad-obs)))
     (check-equal? (ds-orientation-mode (ds-model-orientation anchored)) 'anchor-rule)
     (define dev-labels
       (list (gold-label good-obs #t)
             (gold-label bad-obs #f)))
     (define dev-oriented (orient-ds-model flipped (ds-orientation 'dev-gold #f 1) dev-labels))
     (check-true (> (ds-posterior dev-oriented good-obs)
                    (ds-posterior dev-oriented bad-obs))))

   (test-case "per-constraint DS returns posterior vector and fallback"
     (define model
       (fit-per-constraint-ds (ds-config 100 1e-7 1.0 0.5)
                              synthetic-constraint-observations))
     (check-true (hash-has-key? (per-constraint-ds-model-models model) 'word-count))
     (check-false (hash-has-key? (per-constraint-ds-model-models model) 'rare))
     (check-not-false (per-constraint-ds-model-fallback-model model))
     (define ps
       (constraint-posteriors
        model
        (list (cobs 'word-count 'r1 'accept)
              (cobs 'phrase-presence 'r2 'accept)
              (cobs 'rare 'r1 'accept))))
     (check-true (hash-has-key? ps 'word-count))
     (check-true (hash-has-key? ps 'phrase-presence))
     (check-true (hash-has-key? ps 'rare))
     (for ([p (in-list (hash-values ps))])
       (check-true (<= 0.0 p 1.0)))
     (define trace-json
       (candidate-trace->json
        (candidate-trace "r1" 0 1 "hash" "candidate" '(1) -1.0 0.0 '() ps #t '() #f)))
     (check-true (hash-has-key? (hash-ref trace-json 'constraint_posteriors)
                                "word-count")))))

(module+ test
  (require rackunit/text-ui)
  (run-tests dawid-skene-tests))
