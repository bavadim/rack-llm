#lang typed/racket/base

(require racket/list
         "filter.rkt"
         (only-in "logits.rkt" LogitsView logits-length logits-ref))

(provide CandidatePolicy Sampler (struct-out token-selection)
         make-sampler sampler-select-token log-softmax sample-id)

(define-type TokenId Natural)
(define-type LogitsScratch (Vectorof Real))
(define-type CandidatePolicy (U 'full-vocab 'allowed-only (List 'top-k Positive-Integer)))

(struct sampler ([candidate-policy : CandidatePolicy]
                 [beta : Real]
                 [lambda-weight : Real]
                 [temperature : Real]
                 [rng : Pseudo-Random-Generator]
                 [token-adjustments : LogitsScratch])
  #:transparent)
(define-type Sampler sampler)

(struct token-selection ([id : (Option TokenId)]
                         [lm-logprob : Real]
                         [adjustment : Real]
                         [dead-count : Natural]
                         [next-state : (Option FilterState)]
                         [candidate-count : Natural])
  #:transparent)

(: make-sampler (-> Natural CandidatePolicy Real Real Real (Option Integer) Sampler))
(define (make-sampler vocab-size candidate-policy beta lambda-weight temperature seed)
  (unless (> temperature 0.0) (raise-argument-error 'generate "positive temperature" temperature))
  (sampler candidate-policy
           beta
           lambda-weight
           temperature
           (make-rng seed)
           (make-vector vocab-size 0.0)))

(: sampler-select-token (-> Sampler Filter FilterState LogitsView Real Real token-selection))
(define (sampler-select-token sampler f state logits last-score last-potential)
  (define candidate-policy (sampler-candidate-policy sampler))
  (define beta (sampler-beta sampler))
  (define lambda-weight (sampler-lambda-weight sampler))
  (define temperature (sampler-temperature sampler))
  (define rng (sampler-rng sampler))
  (define token-adjustments (sampler-token-adjustments sampler))
  (cond
    [(and (eq? candidate-policy 'full-vocab)
          (filter-fill-token-adjustments! f state token-adjustments
                                          beta lambda-weight))
     (select-token/full-vocab-fast f state logits token-adjustments temperature rng)]
    [else
     (select-token/generic f state logits candidate-policy
                           last-score last-potential beta lambda-weight temperature rng)]))

(: select-token/generic
   (-> Filter FilterState LogitsView CandidatePolicy Real Real Real Real Real
       Pseudo-Random-Generator token-selection))
(define (select-token/generic f state logits candidate-policy
                              last-score last-potential beta lambda-weight temperature rng)
  (define log-z (logits-log-z logits))
  (define candidate-count : Natural 0)
  (: step-candidate
     (-> TokenId
         (Option TokenId)
         Real
         Real
         Real
         (Option FilterState)
         Natural
         (Values (Option TokenId) Real Real Real (Option FilterState) Natural)))
  (define (step-candidate id best-id best-score best-lm best-adjustment best-state dead)
    (define raw (logits-ref logits id))
    (cond
      [(log-score-dead? raw)
       (values best-id best-score best-lm best-adjustment best-state (add1 dead))]
      [else
       (define next-state (filter-step f state id))
       (cond
         [(filter-dead? next-state)
          (values best-id best-score best-lm best-adjustment best-state (add1 dead))]
         [else
          (define next-score (filter-score next-state))
          (define next-potential (filter-potential next-state))
          (define delta-score (- next-score last-score))
          (define delta-potential (- next-potential last-potential))
          (define adjustment (* beta (+ delta-score (* lambda-weight delta-potential))))
          (define adjusted (+ raw adjustment))
          (define sample-score (+ (/ adjusted temperature) (gumbel/current)))
          (if (> sample-score best-score)
              (values id sample-score (logit-logprob raw log-z) adjustment next-state dead)
              (values best-id best-score best-lm best-adjustment best-state dead))])]))
  (define-values (best-id best-score best-lm best-adjustment best-state dead)
    (parameterize ([current-pseudo-random-generator rng])
      (cond
        [(eq? candidate-policy 'allowed-only)
         (define allowed (filter-allowed-ids f state))
         (cond
           [allowed
            (set! candidate-count (length allowed))
            (for/fold ([best-id : (Option TokenId) #f]
                       [best-score : Real -inf.0]
                       [best-lm : Real -inf.0]
                       [best-adjustment : Real 0.0]
                       [best-state : (Option FilterState) #f]
                       [dead : Natural 0])
                      ([id (in-list allowed)])
              (step-candidate id best-id best-score best-lm best-adjustment best-state dead))]
           [else
            (set! candidate-count (logits-length logits))
            (for/fold ([best-id : (Option TokenId) #f]
                       [best-score : Real -inf.0]
                       [best-lm : Real -inf.0]
                       [best-adjustment : Real 0.0]
                       [best-state : (Option FilterState) #f]
                       [dead : Natural 0])
                      ([id : Natural (in-range (logits-length logits))])
              (step-candidate id best-id best-score best-lm best-adjustment best-state dead))])]
        [(eq? candidate-policy 'full-vocab)
         (set! candidate-count (logits-length logits))
         (for/fold ([best-id : (Option TokenId) #f]
                    [best-score : Real -inf.0]
                    [best-lm : Real -inf.0]
                    [best-adjustment : Real 0.0]
                    [best-state : (Option FilterState) #f]
                    [dead : Natural 0])
                   ([id : Natural (in-range (logits-length logits))])
           (step-candidate id best-id best-score best-lm best-adjustment best-state dead))]
        [else
         (define ids (top-k-ids logits (cadr candidate-policy)))
         (set! candidate-count (length ids))
         (for/fold ([best-id : (Option TokenId) #f]
                    [best-score : Real -inf.0]
                    [best-lm : Real -inf.0]
                    [best-adjustment : Real 0.0]
                    [best-state : (Option FilterState) #f]
                    [dead : Natural 0])
                   ([id (in-list ids)])
           (step-candidate id best-id best-score best-lm best-adjustment best-state dead))])))
  (token-selection best-id best-lm best-adjustment dead best-state candidate-count))

(: select-token/full-vocab-fast
   (-> Filter FilterState LogitsView LogitsScratch Real Pseudo-Random-Generator token-selection))
(define (select-token/full-vocab-fast f state logits token-adjustments temperature rng)
  (define vocab-size (logits-length logits))
  (define log-z (logits-log-z logits))
  (define-values (best-id best-score best-lm best-adjustment dead)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option TokenId) #f]
                 [best-score : Real -inf.0]
                 [best-lm : Real -inf.0]
                 [best-adjustment : Real 0.0]
                 [dead : Natural 0])
                ([id : Natural (in-range vocab-size)])
        (define raw (logits-ref logits id))
        (define adjustment (vector-ref token-adjustments id))
        (cond
          [(or (log-score-dead? raw)
               (log-score-dead? adjustment))
           (values best-id best-score best-lm best-adjustment (add1 dead))]
          [else
           (define adjusted (+ raw adjustment))
           (define sample-score (+ (/ adjusted temperature) (gumbel/current)))
           (if (> sample-score best-score)
               (values id sample-score (logit-logprob raw log-z) adjustment dead)
               (values best-id best-score best-lm best-adjustment dead))]))))
  (define best-state
    (and best-id
         (filter-step f state (assert best-id exact-nonnegative-integer?))))
  (if (and best-state (filter-dead? best-state))
      (token-selection #f -inf.0 0.0 (add1 dead) #f vocab-size)
      (token-selection best-id best-lm best-adjustment dead best-state vocab-size)))

(: top-k-ids (-> LogitsView Positive-Integer (Listof TokenId)))
(define (top-k-ids logits k)
  (define pairs
    (for/list : (Listof (Pairof TokenId Real))
              ([id : Natural (in-range (logits-length logits))])
      (cons id (logits-ref logits id))))
  (define sorted
    (sort pairs
          (lambda ([a : (Pairof TokenId Real)] [b : (Pairof TokenId Real)])
            (> (cdr a) (cdr b)))))
  (for/list : (Listof TokenId) ([pair (in-list (take sorted (min k (logits-length logits))))])
    (car pair)))

(: log-softmax (-> LogitsView (Vectorof Real)))
(define (log-softmax logits)
  (define log-z (logits-log-z logits))
  (if (log-score-dead? log-z)
      (for/vector : (Vectorof Real) ([_id : Natural (in-range (logits-length logits))]) -inf.0)
      (for/vector : (Vectorof Real) ([id : Natural (in-range (logits-length logits))])
        (define x (logits-ref logits id))
        (logit-logprob x log-z))))

(: logits-log-z (-> LogitsView Real))
(define (logits-log-z logits)
  (define max-logit
    (for/fold ([best : Real -inf.0])
              ([id : Natural (in-range (logits-length logits))])
      (max best (logits-ref logits id))))
  (if (log-score-dead? max-logit)
      -inf.0
      (assert (+ max-logit
                 (log (for/sum : Real ([id : Natural (in-range (logits-length logits))])
                        (define x (logits-ref logits id))
                        (if (log-score-dead? x) 0.0 (exp (- x max-logit))))))
              real?)))

(: logit-logprob (-> Real Real Real))
(define (logit-logprob raw log-z)
  (if (or (log-score-dead? raw) (log-score-dead? log-z))
      -inf.0
      (assert (- raw log-z) real?)))

(: sample-id (-> LogitsView Pseudo-Random-Generator Real TokenId))
(define (sample-id adjusted-logits rng temperature)
  (define-values (id _score)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option TokenId) #f] [best-score : Real -inf.0])
                ([id : Natural (in-range (logits-length adjusted-logits))])
        (define logit (logits-ref adjusted-logits id))
        (define score (+ (/ logit temperature) (gumbel/current)))
        (if (and (not (log-score-dead? logit))
                 (> score best-score))
            (values id score)
            (values best-id best-score)))))
  (unless id (error 'sample-id "no sampleable token"))
  id)

(: make-rng (-> (Option Integer) Pseudo-Random-Generator))
(define (make-rng seed)
  (define rng (make-pseudo-random-generator))
  (when seed
    (parameterize ([current-pseudo-random-generator rng])
      (random-seed (add1 (abs seed)))))
  rng)

(: gumbel (-> Pseudo-Random-Generator Real))
(define (gumbel rng)
  (parameterize ([current-pseudo-random-generator rng])
    (gumbel/current)))

(: gumbel/current (-> Real))
(define (gumbel/current)
  (define u (max 1e-12 (min (- 1.0 1e-12) (random))))
  (assert (- (log (- (log u)))) real?))
