#lang racket/base

(require racket/list
         rack-llm/rules/acceptance)

(provide (struct-out ds-config)
         (struct-out ds-orientation)
         (struct-out gold-label)
         (struct-out ds-model)
         (struct-out constraint-observation)
         (struct-out per-constraint-ds-model)
         default-ds-config
         fit-dawid-skene
         fit-per-constraint-ds
         ds-posterior
         constraint-posteriors
         orient-ds-model
         ds-model->json
         json->ds-model
         ds-rule-outcome-prob
         estimated-accuracy)

(struct ds-config
  (max-iter
   tol
   smoothing
   prior-good)
  #:transparent)

(struct ds-orientation
  (mode
   anchor-rule-id
   good-class)
  #:transparent)

(struct gold-label
  (observations
   good?)
  #:transparent)

(struct ds-model
  (rule-ids
   prior-good
   confusions
   iterations
   converged?
   orientation)
  #:transparent)

(struct constraint-observation
  (constraint-id
   rule-observation)
  #:transparent)

(struct per-constraint-ds-model
  (models
   fallback-model)
  #:transparent)

(define default-ds-config
  (ds-config 100 1e-6 1.0 0.5))

(define outcomes '(accept reject abstain))
(define classes '(0 1))
(define default-orientation (ds-orientation 'manual #f 1))
(define min-constraint-examples 2)

(define (fit-dawid-skene config observation-sets)
  (define rule-ids (collect-rule-ids observation-sets))
  (define starting-confusions (initial-confusions rule-ids))
  (define initial-posteriors
    (map (lambda (observations)
           (initial-posterior (ds-config-prior-good config) observations))
         observation-sets))
  (let loop ([iteration 0]
             [prior-good (ds-config-prior-good config)]
             [confusions starting-confusions]
             [posteriors initial-posteriors])
    (cond
      [(>= iteration (ds-config-max-iter config))
       (ds-model rule-ids prior-good confusions iteration #f default-orientation)]
      [else
       (define model (ds-model rule-ids prior-good confusions iteration #f default-orientation))
       (define next-posteriors
         (map (lambda (observations) (ds-posterior model observations))
              observation-sets))
       (define delta (max-posterior-delta posteriors next-posteriors))
       (define next-prior (mean/default next-posteriors prior-good))
       (define next-confusions
         (estimate-confusions rule-ids
                              observation-sets
                              next-posteriors
                              (ds-config-smoothing config)))
       (cond
         [(<= delta (ds-config-tol config))
          (ds-model rule-ids next-prior next-confusions (add1 iteration) #t default-orientation)]
         [else
         (loop (add1 iteration) next-prior next-confusions next-posteriors)])])))

(define (fit-per-constraint-ds config constraint-observation-sets)
  (define fallback-observation-sets
    (map constraint-observations->rule-observations constraint-observation-sets))
  (define fallback-model
    (and (has-any-observations? fallback-observation-sets)
         (fit-dawid-skene config fallback-observation-sets)))
  (define constraint-ids (collect-constraint-ids constraint-observation-sets))
  (define models
    (for/hash ([constraint-id (in-list constraint-ids)])
      (define grouped (constraint-rule-observation-sets constraint-id constraint-observation-sets))
      (if (>= (length grouped) min-constraint-examples)
          (values constraint-id (fit-dawid-skene config grouped))
          (values constraint-id #f))))
  (per-constraint-ds-model (filter-fitted-models models) fallback-model))

(define (constraint-posteriors model observations)
  (define constraint-ids (collect-constraint-ids (list observations)))
  (for/hash ([constraint-id (in-list constraint-ids)])
    (define rule-observations
      (map constraint-observation-rule-observation
           (filter (lambda (observation)
                     (eq? constraint-id (constraint-observation-constraint-id observation)))
                   observations)))
    (define ds
      (hash-ref (per-constraint-ds-model-models model)
                constraint-id
                (lambda () (per-constraint-ds-model-fallback-model model))))
    (values constraint-id
            (if ds
                (ds-posterior ds rule-observations)
                0.5))))

(define (ds-posterior model observations)
  (define prior-good (clamp-prob (ds-model-prior-good model)))
  (define log-good (log prior-good))
  (define log-bad (log (- 1.0 prior-good)))
  (define log-good*
    (+ log-good
       (sum-map (lambda (observation)
                  (log (clamp-prob (ds-rule-outcome-prob model
                                                         (rule-observation-rule-id observation)
                                                         1
                                                         (rule-observation-decision observation)))))
                observations)))
  (define log-bad*
    (+ log-bad
       (sum-map (lambda (observation)
                  (log (clamp-prob (ds-rule-outcome-prob model
                                                         (rule-observation-rule-id observation)
                                                         0
                                                         (rule-observation-decision observation)))))
                observations)))
  (logistic-normalize log-good* log-bad*))

(define (ds-rule-outcome-prob model rule-id class outcome)
  (define rule-confusion (hash-ref (ds-model-confusions model) rule-id #f))
  (cond
    [(not rule-confusion) (/ 1.0 (length outcomes))]
    [else
     (define class-confusion (hash-ref rule-confusion class #f))
     (cond
       [(not class-confusion) (/ 1.0 (length outcomes))]
       [else (hash-ref class-confusion outcome (/ 1.0 (length outcomes)))])]))

(define (estimated-accuracy model rule-id)
  (ds-rule-outcome-prob model rule-id 1 'accept))

(define (orient-ds-model model orientation gold-labels)
  (case (ds-orientation-mode orientation)
    [(manual)
     (orient-by-class model orientation (ds-orientation-good-class orientation))]
    [(anchor-rule)
     (define anchor-rule-id (ds-orientation-anchor-rule-id orientation))
     (unless anchor-rule-id
       (error 'orient-ds-model "anchor-rule orientation requires anchor-rule-id"))
     (define class0 (ds-rule-outcome-prob model anchor-rule-id 0 'accept))
     (define class1 (ds-rule-outcome-prob model anchor-rule-id 1 'accept))
     (define good-class (if (> class0 class1) 0 1))
     (orient-by-class model
                      (ds-orientation 'anchor-rule anchor-rule-id good-class)
                      good-class)]
    [(dev-gold)
     (unless gold-labels
       (error 'orient-ds-model "dev-gold orientation requires dev gold labels"))
     (define keep-auc (dev-auroc model gold-labels))
     (define flipped (flip-ds-model model (ds-orientation 'dev-gold #f 0)))
     (define flip-auc (dev-auroc flipped gold-labels))
     (if (> flip-auc keep-auc)
         flipped
         (set-model-orientation model (ds-orientation 'dev-gold #f 1)))]
    [else
     (error 'orient-ds-model
            "unsupported orientation mode: ~a"
            (ds-orientation-mode orientation))]))

(define (orient-by-class model orientation good-class)
  (case good-class
    [(1) (set-model-orientation model orientation)]
    [(0) (flip-ds-model model orientation)]
    [else (error 'orient-ds-model "good-class must be 0 or 1: ~a" good-class)]))

(define (set-model-orientation model orientation)
  (ds-model (ds-model-rule-ids model)
            (ds-model-prior-good model)
            (ds-model-confusions model)
            (ds-model-iterations model)
            (ds-model-converged? model)
            orientation))

(define (flip-ds-model model orientation)
  (ds-model (ds-model-rule-ids model)
            (- 1.0 (ds-model-prior-good model))
            (flip-confusions (ds-model-confusions model))
            (ds-model-iterations model)
            (ds-model-converged? model)
            orientation))

(define (flip-confusions confusions)
  (for/hash ([(rule-id rule-confusion) (in-hash confusions)])
    (values rule-id
            (hash 0 (hash-ref rule-confusion 1)
                  1 (hash-ref rule-confusion 0)))))

(define (ds-model->json model)
  (hash 'schema_version "1"
        'rule_ids (map symbol->string (ds-model-rule-ids model))
        'prior_good (ds-model-prior-good model)
        'confusions (confusions->json (ds-model-confusions model))
        'iterations (ds-model-iterations model)
        'converged (ds-model-converged? model)
        'orientation (orientation->json (ds-model-orientation model))))

(define (json->ds-model js)
  (unless (hash? js)
    (error 'json->ds-model "expected hash JSON object: ~e" js))
  (ds-model (map string->symbol (hash-ref js 'rule_ids))
            (exact->inexact (hash-ref js 'prior_good))
            (json->confusions (hash-ref js 'confusions))
            (hash-ref js 'iterations)
            (hash-ref js 'converged)
            (json->orientation
             (hash-ref js
                       'orientation
                       (lambda () (orientation->json default-orientation))))))

(define (collect-rule-ids observation-sets)
  (remove-duplicates
   (for*/list ([observations (in-list observation-sets)]
               [observation (in-list observations)])
     (rule-observation-rule-id observation))))

(define (collect-constraint-ids constraint-observation-sets)
  (remove-duplicates
   (for*/list ([observations (in-list constraint-observation-sets)]
               [observation (in-list observations)])
     (constraint-observation-constraint-id observation))))

(define (constraint-observations->rule-observations observations)
  (map constraint-observation-rule-observation observations))

(define (constraint-rule-observation-sets constraint-id constraint-observation-sets)
  (filter (lambda (observations) (not (null? observations)))
          (map (lambda (observations)
                 (map constraint-observation-rule-observation
                      (filter (lambda (observation)
                                (eq? constraint-id
                                     (constraint-observation-constraint-id observation)))
                              observations)))
               constraint-observation-sets)))

(define (has-any-observations? observation-sets)
  (for/or ([observations (in-list observation-sets)])
    (not (null? observations))))

(define (filter-fitted-models models)
  (for/hash ([(constraint-id maybe-model) (in-hash models)]
             #:when maybe-model)
    (values constraint-id maybe-model)))

(define (initial-posterior prior-good observations)
  (define accepts (count-observations 'accept observations))
  (define rejects (count-observations 'reject observations))
  (cond
    [(> accepts rejects) 0.8]
    [(> rejects accepts) 0.2]
    [else prior-good]))

(define (initial-confusions rule-ids)
  (for/hash ([rule-id (in-list rule-ids)])
    (values rule-id
            (hash 0 (hash 'accept 0.2 'reject 0.7 'abstain 0.1)
                  1 (hash 'accept 0.7 'reject 0.2 'abstain 0.1)))))

(define (estimate-confusions rule-ids observation-sets posteriors smoothing)
  (for/hash ([rule-id (in-list rule-ids)])
    (values rule-id
            (for/hash ([class (in-list classes)])
              (values class
                      (estimate-outcome-probs rule-id
                                              class
                                              observation-sets
                                              posteriors
                                              smoothing))))))

(define (estimate-outcome-probs rule-id class observation-sets posteriors smoothing)
  (define denominator
    (+ (* smoothing (length outcomes))
       (for/sum ([observations (in-list observation-sets)]
                 [eta (in-list posteriors)])
         (if (observed-rule? rule-id observations)
             (class-weight class eta)
             0.0))))
  (for/hash ([outcome (in-list outcomes)])
    (values outcome
            (/ (+ smoothing
                  (for/sum ([observations (in-list observation-sets)]
                            [eta (in-list posteriors)])
                    (weighted-outcome-count rule-id outcome class observations eta)))
               denominator))))

(define (weighted-outcome-count rule-id outcome class observations eta)
  (* (class-weight class eta)
     (for/sum ([observation (in-list observations)])
       (if (and (eq? rule-id (rule-observation-rule-id observation))
                (eq? outcome (rule-observation-decision observation)))
           1.0
           0.0))))

(define (observed-rule? rule-id observations)
  (for/or ([observation (in-list observations)])
    (eq? rule-id (rule-observation-rule-id observation))))

(define (class-weight class eta)
  (if (= class 1) eta (- 1.0 eta)))

(define (count-observations decision observations)
  (for/sum ([observation (in-list observations)])
    (if (eq? decision (rule-observation-decision observation)) 1 0)))

(define (max-posterior-delta left right)
  (cond
    [(or (null? left) (null? right)) +inf.0]
    [else
     (apply max
            (for/list ([a (in-list left)]
                       [b (in-list right)])
              (abs (- a b))))]))

(define (mean/default xs default)
  (cond
    [(null? xs) default]
    [else (/ (apply + xs) (length xs))]))

(define (sum-map f xs)
  (for/sum ([x (in-list xs)]) (f x)))

(define (clamp-prob p)
  (max 1e-12 (min (- 1.0 1e-12) (exact->inexact p))))

(define (logistic-normalize log-good log-bad)
  (define m (max log-good log-bad))
  (define good (exp (- log-good m)))
  (define bad (exp (- log-bad m)))
  (/ good (+ good bad)))

(define (dev-auroc model labels)
  (define positives
    (for/list ([label (in-list labels)]
               #:when (gold-label-good? label))
      (ds-posterior model (gold-label-observations label))))
  (define negatives
    (for/list ([label (in-list labels)]
               #:unless (gold-label-good? label))
      (ds-posterior model (gold-label-observations label))))
  (cond
    [(or (null? positives) (null? negatives)) 0.5]
    [else
     (/ (for*/sum ([p (in-list positives)]
                   [n (in-list negatives)])
          (cond
            [(> p n) 1.0]
            [(= p n) 0.5]
            [else 0.0]))
        (* (length positives) (length negatives)))]))

(define (orientation->json orientation)
  (hash 'mode (symbol->string (ds-orientation-mode orientation))
        'anchor_rule_id (let ([rule-id (ds-orientation-anchor-rule-id orientation)])
                          (if rule-id (symbol->string rule-id) 'null))
        'good_class (ds-orientation-good-class orientation)))

(define (json->orientation js)
  (ds-orientation (string->symbol (hash-ref js 'mode))
                  (let ([rule-id (hash-ref js 'anchor_rule_id)])
                    (if (eq? rule-id 'null) #f (string->symbol rule-id)))
                  (hash-ref js 'good_class)))

(define (confusions->json confusions)
  (for/hash ([(rule-id rule-confusion) (in-hash confusions)])
    (values (symbol->string rule-id)
            (for/hash ([class (in-list classes)])
              (values (class->json-key class)
                      (outcome-probs->json (hash-ref rule-confusion class)))))))

(define (outcome-probs->json probs)
  (for/hash ([outcome (in-list outcomes)])
    (values (symbol->string outcome) (hash-ref probs outcome))))

(define (json->confusions js)
  (for/hash ([(rule-key rule-js) (in-hash js)])
    (values (string->symbol rule-key)
            (for/hash ([class (in-list classes)])
              (values class
                      (json->outcome-probs
                       (hash-ref rule-js (class->json-key class))))))))

(define (json->outcome-probs js)
  (for/hash ([outcome (in-list outcomes)])
    (values outcome
            (exact->inexact (hash-ref js (symbol->string outcome))))))

(define (class->json-key class)
  (if (= class 1) "1" "0"))
