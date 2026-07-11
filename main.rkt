#lang typed/racket/base

(require racket/list
         racket/string
         (only-in "private/logits.rkt"
                  LogitsView
                  check-logits-view
                  logits-ref)
         (only-in "private/model.rkt"
                  TokenId
                  TokenIds
                  Provider
                  Model
                  tokenize
                  detokenize
                  token-ref
                  vocab-size
                  provider-next-logits
                  provider-vocab-size
                  provider-eog-token-ids
                  provider-start-session
                  provider-commit-token!
                  provider-end-session!
                  model-tokenizer
                  model-provider
                  model-metadata
                  model-close!
                  model-acquire!
                  model-release!)
         (only-in "private/guidance.rkt"
                  Score
                  Program
                  Guidance
                  TextObserver
                  guidance-step-selection?
                  guidance-step-selection-ids
                  guidance-step-selection-state
                  guidance-step-selection-lm-logprob
                  guidance-step-selection-llm-calls
                  guidance-step-selection-dead-count
                  guidance-step-selection-candidate-count
                  guidance-step-failure?
                  guidance-step-failure-status
                  guidance-step-failure-reason
                  neg-inf
                  log-score-dead?
                  make-lit-program
                  make-rx-program
                  make-pure-program
                  make-choice-program
                  make-seq-program
                  make-repeat-program
                  make-bind-program
                  make-score-program
                  make-text-program
                  make-rank-observer
                  make-ban-observer
                  make-rx-rank-observer
                  make-rx-ban-observer
                  make-weighted-rule
                  make-weighted-observer
                  program-score-ceiling
                  program-dynamic?
                  compile-guidance
                  GuidanceState
                  guidance-initial
                  guidance-step
                  guidance-allowed-token-ids
                  guidance-select-step
                  guidance-accepting?
                  guidance-budget-accepting?
                  guidance-terminal?
                  guidance-dead?
                  guidance-score
                  guidance-accepted-score
                  guidance-potential
                  guidance-value
                  guidance-trace)
         (only-in "private/regex.rkt"
                  make-regex-vocabulary
                  parse-regex-program
                  parse-regex-search-program)
         (only-in "private/sampling.rkt"
                  factor-selection?
                  factor-selection-id
                  factor-selection-base-logprob
                  factor-selection-base-probability
                  factor-selection-frontier-mass
                  factor-selection-candidate-count
                  sample-factor-logits
                  logit-logprob
                  logits-log-z
                  make-rng)
         (only-in "private/cars.rkt"
                  CarsTrie CarsNode TokenDomain
                  make-token-domain token-domain-member?
                  make-cars-trie cars-trie-root cars-trie-node-count cars-trie-frozen?
                  cars-node-mass cars-node-log-factor cars-node-child!
                  cars-node-install-domain! cars-node-set-mass!))

(provide Score
         Model
         model-metadata
         model-close!
         lit
         rx
         pure
         seq
         choice
         repeat
         bind
         score
         text
         rank
         rank-rx
         ban
         ban-rx
         weight
         Sampler Generator
         local-sampler
         cars-sampler
         make-generator
         generator-sample!
         generator-sample-n!
         generator-close!
         (struct-out generation-metrics)
         (struct-out generation-result)
         generate)

;; Public program builders. They are immutable descriptions. `generate` compiles
;; them into token-native guidance with the model tokenizer.

(: lit (-> String Program))
(define (lit source) (make-lit-program source))

(: rx (-> String Program))
(define (rx pattern) (make-rx-program (parse-regex-program pattern)))

(: pure (-> Any Program))
(define (pure value) (make-pure-program value))

(: choice (-> (Listof Program) Program))
(define (choice options) (make-choice-program options))

(: seq (-> (Listof Program) Program))
(define (seq children) (make-seq-program children))

(: repeat (-> Natural Natural Program Program))
(define (repeat min-count max-count item)
  (make-repeat-program min-count max-count item))

(: bind (-> Program (-> Any Program) Program))
(define (bind first continue) (make-bind-program first continue))

(: score (-> Real Program Program))
(define (score amount child) (make-score-program amount child))

(: text (-> Natural (Listof TextObserver) Program))
(define (text max-tokens observers) (make-text-program max-tokens observers))

(: rank (-> Real String TextObserver))
(define (rank amount source) (make-rank-observer amount source))

(: rank-rx (-> Real String TextObserver))
(define (rank-rx amount pattern)
  (make-rx-rank-observer amount (parse-regex-search-program pattern)))

(: ban (-> String TextObserver))
(define (ban source) (make-ban-observer source))

(: ban-rx (-> String TextObserver))
(define (ban-rx pattern)
  (make-rx-ban-observer (parse-regex-search-program pattern)))

(: weight (-> (Listof String) (Listof (Pairof Real String)) TextObserver))
(define (weight samples specs)
  (when (null? samples)
    (raise-argument-error 'weight "non-empty list of strings" samples))
  (when (null? specs)
    (raise-argument-error 'weight "non-empty observer spec list" specs))
  (make-weighted-observer
   (for/list ([spec (in-list specs)])
     (define source (cdr spec))
     (define pos (add1 (count (lambda ([sample : String])
                                (string-contains? sample source))
                              samples)))
     (define neg (add1 (- (length samples) (sub1 pos))))
     (define raw : Real (assert (log (/ pos neg)) real?))
     (define oriented
       (if (negative? (car spec)) (- (abs raw)) (abs raw)))
     (make-weighted-rule oriented source))))

(struct generation-metrics
  ([steps : Natural]
   [generated-tokens : Natural]
   [llm-calls : Natural]
   [dead-token-count : Natural]
   [vocab-size : Natural]
   [candidate-count-total : Natural]
   [candidate-count-per-step : (Listof Natural)]
   [guidance-step-calls : Natural]
   [sampler : Symbol]
   [attempts : Natural]
   [rejected-attempts : Natural]
   [proposed-tokens : Natural]
   [trie-nodes : Natural]
   [root-envelope : Real]
   [trie-frozen? : Boolean])
  #:transparent)

(struct generation-result
  ([status : Symbol]
   [reason : (Option String)]
   [token-ids : TokenIds]
   [text : String]
   [value : Any]
   [lm-logprob : (Option Real)]
   [guidance-score : Real]
   [total-score : (Option Real)]
   [hard-ok? : Boolean]
   [steps : Natural]
   [generated-tokens : Natural]
   [latency-ms : Real]
   [trace : (Listof Any)]
   [metrics : generation-metrics])
  #:transparent)

(: generate/internal
   (->* (Provider TokenIds Guidance)
        (#:beta Real
         #:lambda Real
         #:temperature Real
         #:seed (Option Integer)
         #:rng (Option Pseudo-Random-Generator)
         #:deadline-ms (Option Real)
         #:max-tokens Natural)
        generation-result))
(define (generate/internal p prompt-ids f
                           #:beta [beta 1.0]
                           #:lambda [lambda-weight 0.5]
                           #:temperature [temperature 0.7]
                           #:seed [seed #f]
                           #:rng [supplied-rng #f]
                           #:deadline-ms [deadline-ms #f]
                           #:max-tokens [max-tokens 128])
  (unless (> temperature 0.0)
    (raise-argument-error 'generate "positive temperature" temperature))
  (define started (current-inexact-milliseconds))
  (define rng (or supplied-rng (make-rng seed)))
  (define session : Any (provider-start-session p prompt-ids))
  (define session-closed? : (Boxof Boolean) (box #f))

  (: commit-token! (-> TokenId Void))
  (define (commit-token! id)
    (provider-commit-token! p session id))

  (: commit-segment! (-> TokenIds Void))
  (define (commit-segment! ids)
    (for ([id (in-list ids)])
      (commit-token! id)))

  (: end-session! (-> Void))
  (define (end-session!)
    (unless (unbox session-closed?)
      (set-box! session-closed? #t)
      (provider-end-session! p session)))

  (: finish (-> generation-result generation-result))
  (define (finish result)
    (end-session!)
    result)

  (with-handlers ([exn? (lambda ([failure : exn])
                          (end-session!)
                          (raise failure))])
   (let loop ([step : Natural 0]
             [prefix-ids : TokenIds '()]
             [state : GuidanceState (guidance-initial f)]
             [lm-score : Real 0.0]
             [lm-score-complete? : Boolean #t]
             [llm-calls : Natural 0]
             [dead-count : Natural 0]
             [candidate-total : Natural 0]
             [candidate-counts : (Listof Natural) '()])
    (: result-lm-score (-> (Option Real)))
    (define (result-lm-score)
      (and lm-score-complete? lm-score))
    (cond
      [(deadline-expired? started deadline-ms)
       (finish
        (make-result 'error-budget "deadline exhausted" prefix-ids #f
                     (result-lm-score)
                     (guidance-score state) beta #f step started
                     p llm-calls dead-count candidate-total candidate-counts
                     #:trace (guidance-trace state)))]
      [(or (guidance-dead? state)
           (and (guidance-accepting? state) (guidance-terminal? f state)))
       (finish
        (if (and (not (guidance-dead? state)) (guidance-accepting? state))
            (make-result 'found #f prefix-ids (guidance-value state)
                         (result-lm-score)
                         (guidance-accepted-score state) beta #t step started
                         p llm-calls dead-count candidate-total candidate-counts
                         #:trace (guidance-trace state))
            (make-result 'not-found-hard "guidance is dead" prefix-ids #f
                         (result-lm-score)
                         neg-inf beta #f step started
                         p llm-calls dead-count candidate-total candidate-counts
                         #:trace (guidance-trace state))))]
      [(>= step max-tokens)
       (finish
        (if (guidance-budget-accepting? state)
            (make-result 'found #f prefix-ids (guidance-value state)
                         (result-lm-score)
                         (guidance-accepted-score state) beta #t step started
                         p llm-calls dead-count candidate-total candidate-counts
                         #:trace (guidance-trace state))
            (make-result 'not-found-budget "token budget exhausted" prefix-ids #f
                         (result-lm-score)
                         (guidance-score state) beta #f step started
                         p llm-calls dead-count candidate-total candidate-counts
                         #:trace (guidance-trace state))))]
      [else
       (define remaining-budget
         (assert (- max-tokens step) exact-nonnegative-integer?))
       (: current-logits (-> LogitsView))
       (define (current-logits)
         (provider-next-logits p session))
       (: score-current-segment (-> TokenIds Real))
       (define (score-current-segment ids)
         (score-segment p prompt-ids prefix-ids ids))
       (define step-result
         (guidance-select-step f
                               state
                               remaining-budget
                               (provider-vocab-size p)
                               current-logits
                               score-current-segment
                               beta
                               lambda-weight
                               temperature
                               rng))
       (cond
         [(guidance-step-failure? step-result)
          (finish
           (make-result (guidance-step-failure-status step-result)
                        (guidance-step-failure-reason step-result)
                        prefix-ids
                        #f
                        (result-lm-score)
                        (if (eq? (guidance-step-failure-status step-result) 'not-found-hard)
                            neg-inf
                            (guidance-score state))
                        beta
                        #f
                        step
                        started
                        p
                        llm-calls
                        dead-count
                        candidate-total
                        candidate-counts))]
         [else
          (define selected (assert step-result guidance-step-selection?))
          (define ids (guidance-step-selection-ids selected))
          (commit-segment! ids)
          (define next-prefix (append prefix-ids ids))
          (define next-step (+ step (length ids)))
          (define selected-lm-logprob (guidance-step-selection-lm-logprob selected))
          (define next-lm-complete? (and lm-score-complete? (real? selected-lm-logprob)))
          (loop next-step
                next-prefix
                (guidance-step-selection-state selected)
                (if (real? selected-lm-logprob)
                    (+ lm-score selected-lm-logprob)
                    lm-score)
                next-lm-complete?
                (+ llm-calls (guidance-step-selection-llm-calls selected))
                (+ dead-count (guidance-step-selection-dead-count selected))
                (+ candidate-total (guidance-step-selection-candidate-count selected))
                (cons (guidance-step-selection-candidate-count selected)
                      candidate-counts))])]))))

(: score-segment (-> Provider TokenIds TokenIds TokenIds Real))
(define (score-segment p prompt-ids prefix-ids ids)
  (cond
    [(null? ids) 0.0]
    [else
     (define session (provider-start-session p (append prompt-ids prefix-ids)))
     (dynamic-wind
       void
       (lambda ()
         (for/fold ([total : Real 0.0]) ([id (in-list ids)])
           (define logits (provider-next-logits p session))
           (define logprob (logit-logprob (logits-ref logits id) (logits-log-z logits)))
           (provider-commit-token! p session id)
           (+ total logprob)))
       (lambda () (provider-end-session! p session)))]))

(: make-result
   (->* (Symbol (Option String) TokenIds Any (Option Real) Real Real Boolean Natural Real
                Provider Natural Natural Natural (Listof Natural))
        (#:trace (Listof Any)
         #:sampler Symbol #:attempts Natural #:rejected-attempts Natural
         #:proposed-tokens Natural #:trie (Option CarsTrie))
        generation-result))
(define (make-result status reason ids value lm-score f-score beta hard-ok? steps started
                     p llm-calls dead-count candidate-total candidate-counts
                     #:trace [trace '()]
                     #:sampler [sampler 'local]
                     #:attempts [attempts 1]
                     #:rejected-attempts [rejected-attempts 0]
                     #:proposed-tokens [proposed-tokens steps]
                     #:trie [trie #f])
  (generation-result status reason ids "" value lm-score f-score
                     (combined-score lm-score f-score beta)
                     hard-ok? steps steps
                     (- (current-inexact-milliseconds) started)
                     trace
                     (generation-metrics steps
                                         steps
                                         llm-calls
                                         dead-count
                                         (provider-vocab-size p)
                                         candidate-total
                                         (reverse candidate-counts)
                                         candidate-total
                                         sampler attempts rejected-attempts proposed-tokens
                                         (if trie (cars-trie-node-count trie) 0)
                                         (if trie (cars-node-mass (cars-trie-root trie)) 1.0)
                                         (and trie (cars-trie-frozen? trie)))))

(: result-with-text (-> generation-result String generation-result))
(define (result-with-text result text)
  (generation-result
   (generation-result-status result)
   (generation-result-reason result)
   (generation-result-token-ids result)
   text
   (generation-result-value result)
   (generation-result-lm-logprob result)
   (generation-result-guidance-score result)
   (generation-result-total-score result)
   (generation-result-hard-ok? result)
   (generation-result-steps result)
   (generation-result-generated-tokens result)
   (generation-result-latency-ms result)
   (generation-result-trace result)
   (generation-result-metrics result)))

(: combined-score (-> (Option Real) Real Real (Option Real)))
(define (combined-score lm local beta)
  (and lm
       (if (or (log-score-dead? lm) (log-score-dead? local))
           neg-inf
           (+ lm (* beta local)))))

(: deadline-expired? (-> Real (Option Real) Boolean))
(define (deadline-expired? started deadline-ms)
  (and deadline-ms
       (>= (- (current-inexact-milliseconds) started) deadline-ms)))

;; Sampling families own a whole generation run. Local uses the existing
;; one-path decoder; CARS owns repeated attempts and its persistent envelope.
(struct local-sampler-config ([lambda : Real]) #:transparent)
(struct cars-sampler-config ([max-attempts : Positive-Integer]
                             [max-trie-nodes : (Option Natural)]) #:transparent)
(define-type Sampler (U local-sampler-config cars-sampler-config))

(: local-sampler (->* () (#:lambda Real) Sampler))
(define (local-sampler #:lambda [lambda-weight 0.5])
  (unless (and (>= lambda-weight 0.0) (= lambda-weight lambda-weight)
               (not (eqv? lambda-weight +inf.0)))
    (raise-argument-error 'local-sampler "finite nonnegative lambda" lambda-weight))
  (local-sampler-config lambda-weight))

(: cars-sampler
   (->* (#:max-attempts Positive-Integer)
        (#:max-trie-nodes (Option Natural)) Sampler))
(define (cars-sampler #:max-attempts max-attempts #:max-trie-nodes [max-nodes #f])
  (when (and max-nodes (zero? max-nodes))
    (raise-argument-error 'cars-sampler "positive max-trie-nodes or #f" max-nodes))
  (cars-sampler-config max-attempts max-nodes))

(struct generator-impl
  ([model : Model]
   [provider : Provider]
   [prompt-ids : TokenIds]
   [guidance : Guidance]
   [sampler : Sampler]
   [score-ceiling : (Option Real)]
   [beta : Real]
   [temperature : Real]
   [max-tokens : Natural]
   [rng : Pseudo-Random-Generator]
   [trie : (Option CarsTrie)]
   [closed? : (Boxof Boolean)]
   [busy? : (Boxof Boolean)])
  #:transparent)
(define-type Generator generator-impl)

(struct pending-domain ([node : CarsNode] [domain : TokenDomain] [mass : Real]) #:transparent)
(struct cars-proposal
  ([accepted? : Boolean]
   [ids : TokenIds]
   [state : GuidanceState]
   [base-logprob : Real]
   [proposed : Natural]
   [llm-calls : Natural]
   [pending : (Listof pending-domain)]
   [terminal-node : (Option CarsNode)]
   [target-mass : Real])
  #:transparent)

(: make-generator
   (->* (Model String Program)
        (#:sampler Sampler #:beta Real #:temperature Real
         #:max-tokens Natural #:seed (Option Integer))
        Generator))
(define (make-generator m prompt builder
                        #:sampler [sampler (local-sampler)]
                        #:beta [beta 1.0]
                        #:temperature [temperature 0.7]
                        #:max-tokens [max-tokens 128]
                        #:seed [seed #f])
  (unless (and (>= beta 0.0) (= beta beta) (not (eqv? beta +inf.0)))
    (raise-argument-error 'make-generator "finite nonnegative beta" beta))
  (unless (and (> temperature 0.0) (= temperature temperature)
               (not (eqv? temperature +inf.0)))
    (raise-argument-error 'make-generator "finite positive temperature" temperature))
  (when (and (cars-sampler-config? sampler) (> beta 0.0) (program-dynamic? builder))
    (error 'make-generator "weighted CARS does not support bind"))
  (when (and (cars-sampler-config? sampler) (> beta 0.0)
             (not (program-score-ceiling builder)))
    (error 'make-generator "weighted CARS requires a finite score ceiling"))
  (model-acquire! m)
  (with-handlers ([exn:fail? (lambda ([exn : exn:fail])
                               (model-release! m)
                               (raise exn))])
    (define tok (model-tokenizer m))
    (define p (model-provider m))
    (define token-texts
      (for/vector : (Vectorof String) ([id : Natural (in-range (vocab-size tok))])
        (token-ref tok id)))
    (define f
      (compile-guidance builder
                        (lambda ([source : String]) (tokenize tok source))
                        (make-regex-vocabulary token-texts)))
    (generator-impl
     m p (tokenize tok prompt) f sampler (program-score-ceiling builder)
     beta temperature max-tokens (make-rng seed)
     (and (cars-sampler-config? sampler)
          (make-cars-trie (cars-sampler-config-max-trie-nodes sampler)))
     (box #f) (box #f))))

(: generator-close! (-> Generator Void))
(define (generator-close! generator)
  (when (unbox (generator-impl-busy? generator))
    (error 'generator-close! "generator is busy"))
  (unless (unbox (generator-impl-closed? generator))
    (set-box! (generator-impl-closed? generator) #t)
    (model-release! (generator-impl-model generator))))

(: generator-sample!
   (->* (Generator) (#:deadline-ms (Option Real)) generation-result))
(define (generator-sample! generator #:deadline-ms [deadline-ms #f])
  (when (unbox (generator-impl-closed? generator))
    (error 'generator-sample! "generator is closed"))
  (when (unbox (generator-impl-busy? generator))
    (error 'generator-sample! "generator is already sampling"))
  (set-box! (generator-impl-busy? generator) #t)
  (dynamic-wind
    void
    (lambda ()
      (define result
        (if (local-sampler-config? (generator-impl-sampler generator))
            (generate/internal
             (generator-impl-provider generator)
             (generator-impl-prompt-ids generator)
             (generator-impl-guidance generator)
             #:beta (generator-impl-beta generator)
             #:lambda (local-sampler-config-lambda
                       (assert (generator-impl-sampler generator) local-sampler-config?))
             #:temperature (generator-impl-temperature generator)
             #:rng (generator-impl-rng generator)
             #:deadline-ms deadline-ms
             #:max-tokens (generator-impl-max-tokens generator))
            (sample-cars generator deadline-ms)))
      (result-with-text
       result
       (detokenize (model-tokenizer (generator-impl-model generator))
                   (generation-result-token-ids result))))
    (lambda () (set-box! (generator-impl-busy? generator) #f))))

(: generator-sample-n!
   (->* (Generator Natural) (#:deadline-ms (Option Real)) (Listof generation-result)))
(define (generator-sample-n! generator count #:deadline-ms [deadline-ms #f])
  (for/list : (Listof generation-result) ([_i (in-range count)])
    (generator-sample! generator #:deadline-ms deadline-ms)))

(: generate
   (->* (Model String Program)
        (#:sampler Sampler #:beta Real #:temperature Real #:seed (Option Integer)
         #:deadline-ms (Option Real) #:max-tokens Natural)
        generation-result))
(define (generate m prompt builder
                  #:sampler [sampler (local-sampler)]
                  #:beta [beta 1.0]
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128])
  (define generator
    (make-generator m prompt builder #:sampler sampler #:beta beta
                    #:temperature temperature #:seed seed #:max-tokens max-tokens))
  (dynamic-wind
    void
    (lambda () (generator-sample! generator #:deadline-ms deadline-ms))
    (lambda () (generator-close! generator))))

(: sample-cars (-> Generator (Option Real) generation-result))
(define (sample-cars generator deadline-ms)
  (define config (assert (generator-impl-sampler generator) cars-sampler-config?))
  (define trie (assert (generator-impl-trie generator) values))
  (define started (current-inexact-milliseconds))
  (let loop : generation-result ([attempt : Positive-Integer 1]
                                 [rejected : Natural 0]
                                 [proposed-total : Natural 0]
                                 [llm-total : Natural 0])
    (cond
      [(deadline-expired? started deadline-ms)
       (cars-failure generator trie 'error-budget "deadline exhausted" started
                     (sub1 attempt) rejected proposed-total llm-total)]
      [(> attempt (cars-sampler-config-max-attempts config))
       (cars-failure generator trie 'not-found-attempts "CARS attempt budget exhausted"
                     started (sub1 attempt) rejected proposed-total llm-total)]
      [(<= (cars-node-mass (cars-trie-root trie)) 0.0)
       (cars-failure generator trie 'not-found-hard "CARS envelope is empty"
                     started (sub1 attempt) rejected proposed-total llm-total)]
      [else
       (define proposal (cars-attempt generator trie started deadline-ms))
       (for ([update (in-list (cars-proposal-pending proposal))])
         (cars-node-install-domain! (pending-domain-node update)
                                    (pending-domain-domain update)
                                    (pending-domain-mass update)))
       (define terminal-node (cars-proposal-terminal-node proposal))
       (when terminal-node
         (cars-node-set-mass! terminal-node (cars-proposal-target-mass proposal)))
       (define next-proposed (+ proposed-total (cars-proposal-proposed proposal)))
       (define next-llm (+ llm-total (cars-proposal-llm-calls proposal)))
       (if (cars-proposal-accepted? proposal)
           (make-result
            'found #f (cars-proposal-ids proposal)
            (guidance-value (cars-proposal-state proposal))
            (cars-proposal-base-logprob proposal)
            (guidance-accepted-score (cars-proposal-state proposal))
            (/ (generator-impl-beta generator) (generator-impl-temperature generator))
            #t (length (cars-proposal-ids proposal)) started (generator-impl-provider generator)
            next-llm 0 0 '()
            #:trace (guidance-trace (cars-proposal-state proposal))
            #:sampler 'cars #:attempts attempt
            #:rejected-attempts rejected #:proposed-tokens next-proposed #:trie trie)
           (loop (add1 attempt) (add1 rejected) next-proposed next-llm))])))

(: cars-failure
   (-> Generator CarsTrie Symbol String Real Natural Natural Natural Natural generation-result))
(define (cars-failure generator trie status reason started attempts rejected proposed llm-calls)
  (make-result status reason '() #f #f 0.0
               (/ (generator-impl-beta generator) (generator-impl-temperature generator))
               #f 0 started (generator-impl-provider generator) llm-calls 0 0 '()
               #:sampler 'cars #:attempts attempts #:rejected-attempts rejected
               #:proposed-tokens proposed #:trie trie))

(: cars-attempt
   (-> Generator CarsTrie Real (Option Real) cars-proposal))
(define (cars-attempt generator trie started deadline-ms)
  (define p (generator-impl-provider generator))
  (define f (generator-impl-guidance generator))
  (define vocab (provider-vocab-size p))
  (define eog-ids (provider-eog-token-ids p))
  (define session : Any (provider-start-session p (generator-impl-prompt-ids generator)))
  (dynamic-wind
    void
    (lambda ()
      (let loop : cars-proposal ([depth : Natural 0]
                 [ids : TokenIds '()]
                 [state : GuidanceState (guidance-initial f)]
                 [node : (Option CarsNode) (cars-trie-root trie)]
                 [base-score : Real 0.0]
                 [proposed : Natural 0]
                 [llm-calls : Natural 0]
                 [pending : (Listof pending-domain) '()])
        (cond
          [(deadline-expired? started deadline-ms)
           (cars-proposal #f ids state base-score proposed llm-calls '() #f 1.0)]
          [(>= depth (generator-impl-max-tokens generator))
           (define child (and node (cars-node-child! trie node vocab 1.0)))
           (if (guidance-accepting? state)
               (weighted-terminal generator ids state base-score proposed llm-calls pending child)
               (cars-proposal #f ids state base-score proposed llm-calls pending child 0.0))]
          [else
           (define content-allowed
             (filter (lambda ([id : TokenId]) (not (and (member id eog-ids) #t)))
                     (guidance-allowed-token-ids f state vocab)))
           (define allowed
             (sort (append content-allowed
                           (if (guidance-accepting? state) eog-ids '())) <))
           (define domain (make-token-domain allowed vocab))
           (define selection
             (sample-factor-logits
              (provider-next-logits p session)
              (generator-impl-rng generator)
              (generator-impl-temperature generator)
              (if node
                  (lambda ([id : TokenId]) (cars-node-log-factor node id))
                  (lambda ([_id : TokenId]) 0.0))
              (lambda ([id : TokenId]) (token-domain-member? domain id))))
           (unless selection (error 'cars "proposal envelope has no sampleable action"))
           (define selected (assert selection factor-selection?))
           (define id (factor-selection-id selected))
           (define child
             (and node
                  (cars-node-child! trie node id
                                    (factor-selection-base-probability selected))))
           (define next-pending
             (if node
                 (cons (pending-domain node domain
                                       (factor-selection-frontier-mass selected)) pending)
                 pending))
           (define next-base (+ base-score (factor-selection-base-logprob selected)))
           (cond
             [(and (member id eog-ids) #t)
              (if (guidance-accepting? state)
                  (weighted-terminal generator ids state next-base proposed (add1 llm-calls)
                                     next-pending child)
                  (cars-proposal #f ids state next-base proposed (add1 llm-calls)
                                 next-pending child 0.0))]
             [else
              (define next-state (guidance-step f state id))
              (if (guidance-dead? next-state)
                  (cars-proposal #f (append ids (list id)) next-state next-base
                                 (add1 proposed) (add1 llm-calls) next-pending child 0.0)
                  (begin
                    (provider-commit-token! p session id)
                    (loop (add1 depth) (append ids (list id)) next-state child next-base
                          (add1 proposed) (add1 llm-calls) next-pending)))])])))
    (lambda () (provider-end-session! p session))))

(: weighted-terminal
   (-> Generator TokenIds GuidanceState Real Natural Natural
       (Listof pending-domain) (Option CarsNode) cars-proposal))
(define (weighted-terminal generator ids state base-score proposed llm-calls pending node)
  (define beta (generator-impl-beta generator))
  (define temperature (generator-impl-temperature generator))
  (define score (guidance-accepted-score state))
  (define ceiling (if (zero? beta) 0.0 (assert (generator-impl-score-ceiling generator) real?)))
  (when (> score (+ ceiling 1e-9))
    (error 'cars "guidance score exceeds its compiled ceiling"))
  (define target-mass
    (if (zero? beta)
        1.0
        (assert (exp (* (/ beta temperature) (- score ceiling))) real?)))
  (define old-mass (if node (cars-node-mass node) 1.0))
  (define accept-prob (if (<= old-mass 0.0) 0.0 (min 1.0 (/ target-mass old-mass))))
  (define accepted?
    (parameterize ([current-pseudo-random-generator (generator-impl-rng generator)])
      (< (random) accept-prob)))
  (cars-proposal accepted? ids state base-score proposed llm-calls pending node target-mass))
