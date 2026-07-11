#lang typed/racket/base

(require (only-in "logits.rkt" LogitsView logits-length logits-ref))

(provide (struct-out scored-selection)
         (struct-out token-sampling-selection)
         (struct-out factor-selection)
         logit-logprob
         logits-log-z
         sample-scored-index
         sample-masked-logits
         sample-logits-with-deltas
         sample-factor-logits
         make-rng)

(define-type TokenId Natural)

(struct scored-selection ([index : Natural]
                          [log-weight : Real])
  #:transparent)

(struct token-sampling-selection ([id : TokenId]
                                  [lm-logprob : Real]
                                  [dead-count : Natural]
                                  [candidate-count : Natural])
  #:transparent)

(struct factor-selection
  ([id : TokenId]
   [base-logprob : Real]
   [base-probability : Real]
   [frontier-mass : Real]
   [candidate-count : Natural])
  #:transparent)

(: sample-scored-index (-> (Vectorof Real) Pseudo-Random-Generator Real (Option scored-selection)))
(define (sample-scored-index log-weights rng temperature)
  (unless (> temperature 0.0)
    (raise-argument-error 'generate "positive temperature" temperature))
  (define-values (best _best-score)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best : (Option scored-selection) #f]
                 [best-score : Real -inf.0])
                ([i : Natural (in-range (vector-length log-weights))])
        (define log-weight (vector-ref log-weights i))
        (cond
          [(log-score-dead? log-weight) (values best best-score)]
          [else
           (define sample-score (+ (/ log-weight temperature) (gumbel/current)))
           (if (> sample-score best-score)
               (values (scored-selection i log-weight) sample-score)
               (values best best-score))]))))
  best)

(: sample-masked-logits
   (-> LogitsView (Listof Natural) Pseudo-Random-Generator Real
       (Option token-sampling-selection)))
(define (sample-masked-logits logits allowed rng temperature)
  (unless (> temperature 0.0)
    (raise-argument-error 'generate "positive temperature" temperature))
  (define candidate-count (length allowed))
  (define-values (best-id _best-score best-raw dead-count log-z _remaining)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option TokenId) #f]
                 [best-score : Real -inf.0]
                 [best-raw : Real -inf.0]
                 [dead-count : Natural 0]
                 [log-z : Real -inf.0]
                 [remaining : (Listof Natural) allowed])
                ([id : Natural (in-range (logits-length logits))])
        (define raw (logits-ref logits id))
        (define next-log-z (log-z-add log-z raw))
        (define allowed? (and (pair? remaining) (= id (car remaining))))
        (define next-remaining (if allowed? (cdr remaining) remaining))
        (cond
          [(or (not allowed?) (log-score-dead? raw))
           (values best-id best-score best-raw (add1 dead-count)
                   next-log-z next-remaining)]
          [else
           (define sample-score (+ (/ raw temperature) (gumbel/current)))
           (if (> sample-score best-score)
               (values id sample-score raw dead-count next-log-z next-remaining)
               (values best-id best-score best-raw dead-count next-log-z next-remaining))]))))
  (and best-id
       (token-sampling-selection best-id
                                 (logit-logprob best-raw log-z)
                                 dead-count
                                 candidate-count)))

(: sample-logits-with-deltas
   (-> LogitsView Pseudo-Random-Generator Real Real (-> TokenId Real)
       (Option token-sampling-selection)))
(define (sample-logits-with-deltas logits rng temperature beta token-delta)
  (unless (> temperature 0.0)
    (raise-argument-error 'generate "positive temperature" temperature))
  (define-values (best-id _best-score best-raw dead-count candidate-count log-z)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option TokenId) #f]
                 [best-score : Real -inf.0]
                 [best-raw : Real -inf.0]
                 [dead-count : Natural 0]
                 [candidate-count : Natural 0]
                 [log-z : Real -inf.0])
                ([id : Natural (in-range (logits-length logits))])
        (define raw (logits-ref logits id))
        (define next-log-z (log-z-add log-z raw))
        (define delta (token-delta id))
        (cond
          [(or (log-score-dead? raw)
               (log-score-dead? delta))
           (values best-id best-score best-raw (add1 dead-count) candidate-count next-log-z)]
          [else
           (define adjusted (+ raw (* beta delta)))
           (define sample-score (+ (/ adjusted temperature) (gumbel/current)))
           (if (> sample-score best-score)
               (values id sample-score raw dead-count (add1 candidate-count) next-log-z)
               (values best-id best-score best-raw dead-count (add1 candidate-count) next-log-z))]))))
  (and best-id
       (token-sampling-selection best-id
                                 (logit-logprob best-raw log-z)
                                 dead-count
                                 candidate-count)))

;; Samples exp(raw / temperature + log-factor). The frontier predicate does
;; not constrain this draw; it measures base probability mass for a CARS
;; update that is committed only after the proposal finishes.
(: sample-factor-logits
   (-> LogitsView Pseudo-Random-Generator Real
       (-> TokenId Real) (-> TokenId Boolean)
       (Option factor-selection)))
(define (sample-factor-logits logits rng temperature log-factor frontier?)
  (unless (> temperature 0.0)
    (raise-argument-error 'sample-factor-logits "positive temperature" temperature))
  (define-values (best-id _best-score best-tempered log-z frontier-z candidate-count)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option TokenId) #f]
                 [best-score : Real -inf.0]
                 [best-tempered : Real -inf.0]
                 [log-z : Real -inf.0]
                 [frontier-z : Real -inf.0]
                 [candidate-count : Natural 0])
                ([id : Natural (in-range (logits-length logits))])
        (define raw (logits-ref logits id))
        (define tempered (if (log-score-dead? raw) -inf.0 (/ raw temperature)))
        (define next-log-z (log-z-add log-z tempered))
        (define next-frontier-z
          (if (and (frontier? id) (not (log-score-dead? tempered)))
              (log-z-add frontier-z tempered)
              frontier-z))
        (define factor (log-factor id))
        (cond
          [(or (log-score-dead? tempered) (log-score-dead? factor))
           (values best-id best-score best-tempered next-log-z next-frontier-z candidate-count)]
          [else
           (define sample-score (+ tempered factor (gumbel/current)))
           (if (> sample-score best-score)
               (values id sample-score tempered next-log-z next-frontier-z
                       (add1 candidate-count))
               (values best-id best-score best-tempered next-log-z next-frontier-z
                       (add1 candidate-count)))]))))
  (and best-id
       (let* ([base-logprob (logit-logprob best-tempered log-z)]
              [frontier-mass
               (if (log-score-dead? frontier-z)
                   0.0
                   (assert (exp (- frontier-z log-z)) real?))])
         (factor-selection best-id
                           base-logprob
                           (assert (exp base-logprob) real?)
                           frontier-mass
                           candidate-count))))

(: logits-log-z (-> LogitsView Real))
(define (logits-log-z logits)
  (for/fold ([log-z : Real -inf.0])
            ([id : Natural (in-range (logits-length logits))])
    (log-z-add log-z (logits-ref logits id))))

(: log-z-add (-> Real Real Real))
(define (log-z-add log-z raw)
  (cond
    [(log-score-dead? raw) log-z]
    [(log-score-dead? log-z) raw]
    [else
     (define m (max log-z raw))
     (assert (+ m (log (+ (exp (- log-z m)) (exp (- raw m))))) real?)]))

(: logit-logprob (-> Real Real Real))
(define (logit-logprob raw log-z)
  (if (or (log-score-dead? raw) (log-score-dead? log-z))
      -inf.0
      (assert (- raw log-z) real?)))

(: make-rng (-> (Option Integer) Pseudo-Random-Generator))
(define (make-rng seed)
  (define rng (make-pseudo-random-generator))
  (when seed
    (parameterize ([current-pseudo-random-generator rng])
      (random-seed (add1 (abs seed)))))
  rng)

(: gumbel/current (-> Real))
(define (gumbel/current)
  (define u (max 1e-12 (min (- 1.0 1e-12) (random))))
  (assert (- (log (- (log u)))) real?))

(: log-score-dead? (-> Real Boolean))
(define (log-score-dead? x) (eqv? x -inf.0))
