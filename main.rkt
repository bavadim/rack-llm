#lang typed/racket/base/no-check

(require racket/list
         (only-in "private/model.rkt"
                  TokenId TokenIds Model Provider
                  tokenize detokenize token-ref vocab-size model-tokenizer model-provider
                  model-metadata model-close! model-acquire! model-release!
                  provider-vocab-size provider-eog-token-ids provider-start-session
                  provider-next-logits provider-commit-token! provider-end-session!)
         (only-in "private/regex.rkt"
                  make-regex-vocabulary parse-regex-program parse-ere-pattern)
         (only-in "private/guidance.rkt"
                  Program ControlRule Guidance GuidanceState
                  make-lit-program make-rx-program make-ere-program make-pure-program
                  make-choice-program make-seq-program make-repeat-program make-bind-program
                  make-text-program make-control-program
                  make-prefer-rule make-avoid-rule make-ban-rule
                  program-pwsg-compatible? program-pwsg-errors program-layout-errors
                  program-schema-descriptors program-canonical-form
                  compile-guidance guidance-initial guidance-step guidance-allowed-token-ids
                  guidance-accepting? guidance-dead? guidance-value guidance-weak-matches
                  guidance-trace)
         (only-in "private/weak.rkt"
                  WeakObservation WeakModel token-span
                  weak-observation? weak-observation-labels weak-observation-rule-paths
                  weak-observation-polarities weak-observation-scope-spans
                  weak-observation-schema-fingerprint weak-observation-spec-fingerprint
                  weak-model? weak-model-fingerprint weak-model-schema-fingerprint
                  weak-model-diagnostics make-weak-observation fit-weak-model weak-posterior
                  save-weak-model load-weak-model)
         (only-in "private/sampling.rkt"
                  factor-selection? factor-selection-id factor-selection-base-probability
                  factor-selection-base-logprob factor-selection-frontier-mass
                  sample-factor-logits make-rng)
         (only-in "private/cars.rkt"
                  CarsTrie CarsNode TokenDomain
                  make-token-domain token-domain-member?
                  make-cars-trie cars-trie-root cars-trie-node-count cars-trie-frozen?
                  cars-node-mass cars-node-log-factor cars-node-child!
                  cars-node-install-domain! cars-node-set-mass!))

(provide Model model-metadata model-close!
         lit rx ere pure seq choice repeat bind text control prefer avoid ban
         pwsg-compatible?
         WeakObservation weak-observation? weak-observation-labels
         weak-observation-rule-paths weak-observation-polarities
         weak-observation-scope-spans weak-observation-schema-fingerprint
         weak-observation-spec-fingerprint token-span
         WeakModel weak-model? weak-model-fingerprint weak-model-schema-fingerprint
         weak-model-diagnostics observe fit-weak-model weak-posterior
         save-weak-model load-weak-model
         Sampler Generator cars-sampler make-generator generator-sample!
         generator-sample-n! generator-close!
         (struct-out weak-result)
         (struct-out generation-metrics)
         (struct-out generation-result)
         generate)

;; DSL -----------------------------------------------------------------------

(: lit (-> String Program))
(define (lit source) (make-lit-program source))
(: rx (-> String Program))
(define (rx source) (make-rx-program (parse-regex-program source)))
(: ere (-> String Program))
(define (ere source) (make-ere-program (parse-ere-pattern source)))
(: pure (-> Any Program))
(define (pure value) (make-pure-program value))
(: seq (-> (Listof Program) Program))
(define (seq programs) (make-seq-program programs))
(: choice (-> (Listof Program) Program))
(define (choice programs) (make-choice-program programs))
(: repeat (-> Natural Natural Program Program))
(define (repeat min-count max-count program) (make-repeat-program min-count max-count program))
(: bind (-> Program (-> Any Program) Program))
(define (bind first continue) (make-bind-program first continue))
(: text (-> Natural Program))
(define (text max-tokens) (make-text-program max-tokens))
(: control (->* (Program) () #:rest ControlRule Program))
(define (control program . rules) (make-control-program program rules))
(: prefer (-> Program ControlRule))
(define (prefer pattern) (make-prefer-rule pattern))
(: avoid (-> Program ControlRule))
(define (avoid pattern) (make-avoid-rule pattern))
(: ban (-> Program ControlRule))
(define (ban pattern) (make-ban-rule pattern))
(: pwsg-compatible? (-> Program Boolean))
(define (pwsg-compatible? program) (program-pwsg-compatible? program))

;; Public results -------------------------------------------------------------

(struct weak-result
  ([observation : WeakObservation]
   [posterior : Real]
   [min-posterior : Real]
   [terminal-mass : Real]
   [terminal-envelope : Real]
   [acceptance-probability : Real]
   [acceptance-draw : Real]
   [model-fingerprint : String]
   [schema-fingerprint : String])
  #:transparent)

(struct generation-metrics
  ([attempts : Natural]
   [rejected-attempts : Natural]
   [hard-invalid-attempts : Natural]
   [hard-proposals : Natural]
   [threshold-rejections : Natural]
   [posterior-rejections : Natural]
   [weak-rejections : Natural]
   [weak-evaluations : Natural]
   [weak-cache-hits : Natural]
   [proposed-tokens : Natural]
   [llm-calls : Natural]
   [vocab-size : Natural]
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
   [target-log-weight : (Option Real)]
   [hard-ok? : Boolean]
   [distribution-guarantee : Symbol]
   [latency-ms : Real]
   [trace : (Listof Any)]
   [observation : (Option WeakObservation)]
   [weak : (Option weak-result)]
   [metrics : generation-metrics])
  #:transparent)

;; Observation ---------------------------------------------------------------

(: compile-for-model (-> Model Program Guidance))
(define (compile-for-model model program)
  (define tokenizer (model-tokenizer model))
  (define token-texts
    (for/vector : (Vectorof String) ([id : Natural (in-range (vocab-size tokenizer))])
      (token-ref tokenizer id)))
  (compile-guidance program
                    (lambda ([source : String]) (tokenize tokenizer source))
                    (make-regex-vocabulary token-texts)))

(: observation-from-state (-> Program GuidanceState WeakObservation))
(define (observation-from-state program state)
  (make-weak-observation (program-schema-descriptors program)
                         (program-canonical-form program)
                         (guidance-weak-matches state)))

(: observe-ids (-> Model Program TokenIds WeakObservation))
(define (observe-ids model program ids)
  (unless (null? (program-layout-errors program))
    (error 'observe "unsupported program layout: ~a" (car (program-layout-errors program))))
  (define guidance (compile-for-model model program))
  (define state
    (for/fold ([state : GuidanceState (guidance-initial guidance)]) ([id (in-list ids)])
      (guidance-step guidance state id)))
  (unless (and (not (guidance-dead? state)) (guidance-accepting? state))
    (error 'observe "candidate is not accepted by the hard program"))
  (observation-from-state program state))

(: observe (-> Model Program (U String generation-result) WeakObservation))
(define (observe model program candidate)
  (cond
    [(generation-result? candidate)
     (define existing (generation-result-observation candidate))
     (if existing
         existing
         (observe-ids model program (generation-result-token-ids candidate)))]
    [else
     (define tokenizer (model-tokenizer model))
     (define ids (tokenize tokenizer candidate))
     (unless (string=? candidate (detokenize tokenizer ids))
       (error 'observe "candidate does not round-trip through the model tokenizer"))
     (observe-ids model program ids)]))

;; Generator -----------------------------------------------------------------

(struct cars-sampler-config
  ([max-attempts : Positive-Integer]
   [max-trie-nodes : (Option Natural)]
   [weak-model : (Option WeakModel)]
   [min-posterior : Real])
  #:transparent)
(define-type Sampler cars-sampler-config)

(: cars-sampler
   (->* (#:max-attempts Positive-Integer)
        (#:max-trie-nodes (Option Natural)
         #:weak-model (Option WeakModel)
         #:min-posterior Real)
        Sampler))
(define (cars-sampler #:max-attempts max-attempts
                      #:max-trie-nodes [max-nodes #f]
                      #:weak-model [model #f]
                      #:min-posterior [min-posterior 0.0])
  (when (and max-nodes (zero? max-nodes))
    (raise-argument-error 'cars-sampler "positive max-trie-nodes or #f" max-nodes))
  (unless (and (<= 0.0 min-posterior 1.0) (= min-posterior min-posterior))
    (raise-argument-error 'cars-sampler "real in [0,1]" min-posterior))
  (when (and (not model) (not (zero? min-posterior)))
    (error 'cars-sampler "min-posterior requires a weak model"))
  (cars-sampler-config max-attempts max-nodes model min-posterior))

(struct terminal-evaluation
  ([observation : WeakObservation] [posterior : Real] [mass : Real])
  #:transparent)

(struct generator-impl
  ([model : Model]
   [provider : Provider]
   [program : Program]
   [prompt-ids : TokenIds]
   [guidance : Guidance]
   [sampler : Sampler]
   [temperature : Real]
   [max-tokens : Natural]
   [rng : Pseudo-Random-Generator]
   [trie : CarsTrie]
   [terminal-cache : (HashTable TokenIds terminal-evaluation)]
   [closed? : (Boxof Boolean)]
   [busy? : (Boxof Boolean)]
   [valid? : (Boxof Boolean)])
  #:transparent)
(define-type Generator generator-impl)

(: make-generator
   (->* (Model String Program #:sampler Sampler)
        (#:temperature Real #:max-tokens Natural #:seed (Option Integer))
        Generator))
(define (make-generator model prompt program #:sampler sampler
                        #:temperature [temperature 0.7]
                        #:max-tokens [max-tokens 128]
                        #:seed [seed #f])
  (unless (and (> temperature 0.0) (= temperature temperature)
               (not (eqv? temperature +inf.0)))
    (raise-argument-error 'make-generator "finite positive temperature" temperature))
  (define layout-errors (program-layout-errors program))
  (unless (null? layout-errors)
    (error 'make-generator "unsupported program layout: ~a" (car layout-errors)))
  (define weak-model (cars-sampler-config-weak-model sampler))
  (when weak-model
    (define profile-errors (program-pwsg-errors program))
    (unless (null? profile-errors)
      (error 'make-generator "unsupported PWSG program: ~a" (car profile-errors)))
    (define empty-observation
      (make-weak-observation (program-schema-descriptors program)
                             (program-canonical-form program) '()))
    (unless (string=? (weak-model-schema-fingerprint weak-model)
                      (weak-observation-schema-fingerprint empty-observation))
      (error 'make-generator "incompatible weak model and program schema")))
  (model-acquire! model)
  (with-handlers ([exn:fail? (lambda ([exn : exn:fail])
                               (model-release! model)
                               (raise exn))])
    (define guidance (compile-for-model model program))
    (generator-impl model (model-provider model) program
                    (tokenize (model-tokenizer model) prompt) guidance sampler
                    temperature max-tokens (make-rng seed)
                    (make-cars-trie (cars-sampler-config-max-trie-nodes sampler))
                    (make-hash) (box #f) (box #f) (box #t))))

(: generator-close! (-> Generator Void))
(define (generator-close! generator)
  (when (unbox (generator-impl-busy? generator))
    (error 'generator-close! "generator is busy"))
  (unless (unbox (generator-impl-closed? generator))
    (set-box! (generator-impl-closed? generator) #t)
    (model-release! (generator-impl-model generator))))

(struct pending-domain ([node : CarsNode] [domain : TokenDomain] [mass : Real]) #:transparent)
(struct terminal-decision
  ([evaluation : terminal-evaluation] [old-envelope : Real]
   [accept-probability : Real] [draw : Real] [cache-hit? : Boolean])
  #:transparent)
(struct cars-proposal
  ([outcome : Symbol]
   [ids : TokenIds]
   [state : GuidanceState]
   [base-logprob : Real]
   [proposed : Natural]
   [llm-calls : Natural]
   [pending : (Listof pending-domain)]
   [terminal-node : (Option CarsNode)]
   [target-mass : Real]
   [decision : (Option terminal-decision)]
   [reason : (Option String)])
  #:transparent)

(: terminal-key (-> TokenIds TokenId TokenIds))
(define (terminal-key ids stop-id) (append ids (list stop-id)))

(: evaluate-terminal
   (-> Generator TokenIds GuidanceState TokenId
       (Values terminal-evaluation Boolean)))
(define (evaluate-terminal generator ids state stop-id)
  (define key (terminal-key ids stop-id))
  (define cached (hash-ref (generator-impl-terminal-cache generator) key #f))
  (if cached
      (values cached #t)
      (let* ([observation (observation-from-state (generator-impl-program generator) state)]
             [config (generator-impl-sampler generator)]
             [model (cars-sampler-config-weak-model config)]
             [posterior (if model (weak-posterior model observation) 1.0)]
             [mass (if (>= posterior (cars-sampler-config-min-posterior config))
                       posterior 0.0)]
             [evaluation (terminal-evaluation observation posterior mass)])
        (hash-set! (generator-impl-terminal-cache generator) key evaluation)
        (values evaluation #f))))

(: decide-terminal
   (-> Generator TokenIds GuidanceState TokenId Real Natural Natural
       (Listof pending-domain) (Option CarsNode) cars-proposal))
(define (decide-terminal generator ids state stop-id base-logprob proposed llm-calls pending node)
  (define-values (evaluation cache-hit?) (evaluate-terminal generator ids state stop-id))
  (define mass (terminal-evaluation-mass evaluation))
  (define old (if node (cars-node-mass node) 1.0))
  (cond
    [(> mass (+ old 1e-12))
     (cars-proposal 'internal-invalid ids state base-logprob proposed llm-calls '() #f old #f
                    "terminal mass exceeds its cached envelope")]
    [else
     (define probability (if (<= old 0.0) 0.0 (/ mass old)))
     (define draw
       (parameterize ([current-pseudo-random-generator (generator-impl-rng generator)])
         (random)))
     (define accepted? (< draw probability))
     (cars-proposal (if accepted? 'accepted
                        (if (zero? mass) 'threshold-rejected 'posterior-rejected))
                    ids state base-logprob proposed llm-calls pending node mass
                    (terminal-decision evaluation old probability draw cache-hit?) #f)]))

(: cars-attempt (-> Generator CarsTrie cars-proposal))
(define (cars-attempt generator trie)
  (define provider (generator-impl-provider generator))
  (define guidance (generator-impl-guidance generator))
  (define vocab (provider-vocab-size provider))
  (define eog-ids (provider-eog-token-ids provider))
  (define session : Any (provider-start-session provider (generator-impl-prompt-ids generator)))
  (dynamic-wind
    void
    (lambda ()
      (let loop : cars-proposal ([depth : Natural 0]
                                 [ids : TokenIds '()]
                                 [state : GuidanceState (guidance-initial guidance)]
                                 [node : (Option CarsNode) (cars-trie-root trie)]
                                 [base : Real 0.0]
                                 [proposed : Natural 0]
                                 [llm-calls : Natural 0]
                                 [pending : (Listof pending-domain) '()])
        (cond
          [(>= depth (generator-impl-max-tokens generator))
           (define child (and node (cars-node-child! trie node vocab 1.0)))
           (if (guidance-accepting? state)
               (decide-terminal generator ids state vocab base proposed llm-calls pending child)
               (cars-proposal 'hard-invalid ids state base proposed llm-calls pending child 0.0 #f
                              "virtual STOP is hard-invalid"))]
          [else
           (define content-allowed
             (filter (lambda ([id : TokenId]) (not (and (member id eog-ids) #t)))
                     (guidance-allowed-token-ids guidance state vocab)))
           (define allowed
             (sort (append content-allowed (if (guidance-accepting? state) eog-ids '())) <))
           (define domain (make-token-domain allowed vocab))
           (define selection
             (sample-factor-logits
              (provider-next-logits provider session)
              (generator-impl-rng generator)
              (generator-impl-temperature generator)
              (if node (lambda ([id : TokenId]) (cars-node-log-factor node id))
                  (lambda ([_id : TokenId]) 0.0))
              (lambda ([id : TokenId]) (token-domain-member? domain id))))
           (unless selection (error 'cars "proposal envelope has no sampleable action"))
           (define selected (assert selection factor-selection?))
           (define id (factor-selection-id selected))
           (define child
             (and node (cars-node-child! trie node id
                                         (factor-selection-base-probability selected))))
           (define next-pending
             (if node
                 (cons (pending-domain node domain (factor-selection-frontier-mass selected)) pending)
                 pending))
           (define next-base (+ base (factor-selection-base-logprob selected)))
           (cond
             [(and (member id eog-ids) #t)
              (if (guidance-accepting? state)
                  (decide-terminal generator ids state id next-base proposed (add1 llm-calls)
                                   next-pending child)
                  (cars-proposal 'hard-invalid ids state next-base proposed (add1 llm-calls)
                                 next-pending child 0.0 #f "EOG is hard-invalid"))]
             [else
              (define next-state (guidance-step guidance state id))
              (if (guidance-dead? next-state)
                  (cars-proposal 'hard-invalid (append ids (list id)) next-state next-base
                                 (add1 proposed) (add1 llm-calls) next-pending child 0.0 #f
                                 "content token made the hard state dead")
                  (begin
                    (provider-commit-token! provider session id)
                    (loop (add1 depth) (append ids (list id)) next-state child next-base
                          (add1 proposed) (add1 llm-calls) next-pending)))])])))
    (lambda () (provider-end-session! provider session))))

(: metrics
   (-> Generator CarsTrie Natural Natural Natural Natural Natural Natural Natural Natural Natural Natural
       generation-metrics))
(define (metrics generator trie attempts rejected hard-invalid hard-proposals threshold-rejections
                 posterior-rejections weak-evaluations weak-cache-hits proposed llm-calls)
  (generation-metrics attempts rejected hard-invalid hard-proposals threshold-rejections
                      posterior-rejections (+ threshold-rejections posterior-rejections)
                      weak-evaluations weak-cache-hits proposed llm-calls
                      (provider-vocab-size (generator-impl-provider generator))
                      (cars-trie-node-count trie) (cars-node-mass (cars-trie-root trie))
                      (cars-trie-frozen? trie)))

(: failure-result
   (-> Generator CarsTrie Symbol String Real Natural Natural Natural Natural Natural Natural Natural Natural Natural Natural
       generation-result))
(define (failure-result generator trie status reason started attempts rejected hard-invalid hard-proposals
                        threshold-rejections posterior-rejections weak-evaluations weak-cache-hits proposed llm-calls)
  (generation-result status reason '() "" #f #f #f #f 'no-sample
                     (- (current-inexact-milliseconds) started) '() #f #f
                     (metrics generator trie attempts rejected hard-invalid hard-proposals
                              threshold-rejections posterior-rejections weak-evaluations
                              weak-cache-hits proposed llm-calls)))

(: sample-cars (-> Generator (Option Real) generation-result))
(define (sample-cars generator deadline-ms)
  (define config (generator-impl-sampler generator))
  (define trie (generator-impl-trie generator))
  (define started (current-inexact-milliseconds))
  (let loop : generation-result ([attempt : Positive-Integer 1]
                                 [rejected : Natural 0]
                                 [hard-invalid : Natural 0]
                                 [hard-proposals : Natural 0]
                                 [threshold-rejections : Natural 0]
                                 [posterior-rejections : Natural 0]
                                 [weak-evaluations : Natural 0]
                                 [weak-cache-hits : Natural 0]
                                 [proposed : Natural 0]
                                 [llm-calls : Natural 0])
    (cond
      [(and deadline-ms (>= (- (current-inexact-milliseconds) started) deadline-ms))
       (failure-result generator trie 'not-found-time-budget "deadline exhausted between attempts"
                       started (sub1 attempt) rejected hard-invalid hard-proposals
                       threshold-rejections posterior-rejections weak-evaluations weak-cache-hits
                       proposed llm-calls)]
      [(> attempt (cars-sampler-config-max-attempts config))
       (failure-result generator trie 'not-found-attempt-budget "CARS attempt budget exhausted"
                       started (sub1 attempt) rejected hard-invalid hard-proposals
                       threshold-rejections posterior-rejections weak-evaluations weak-cache-hits
                       proposed llm-calls)]
      [(<= (cars-node-mass (cars-trie-root trie)) 0.0)
       (failure-result generator trie 'not-found-support
                       (if (zero? hard-proposals) "hard support is empty"
                           "posterior threshold removed the hard support")
                       started (sub1 attempt) rejected hard-invalid hard-proposals
                       threshold-rejections posterior-rejections weak-evaluations weak-cache-hits
                       proposed llm-calls)]
      [else
       (define proposal
         (with-handlers ([exn:fail?
                          (lambda ([exn : exn:fail])
                            (cars-proposal 'backend-error '() (guidance-initial (generator-impl-guidance generator))
                                           0.0 0 0 '() #f 1.0 #f (exn-message exn)))])
           (cars-attempt generator trie)))
       (cond
         [(eq? (cars-proposal-outcome proposal) 'internal-invalid)
          (set-box! (generator-impl-valid? generator) #f)
          (failure-result generator trie 'internal-invalid
                          (or (cars-proposal-reason proposal) "invalid CARS state")
                          started (sub1 attempt) rejected hard-invalid hard-proposals
                          threshold-rejections posterior-rejections weak-evaluations weak-cache-hits
                          proposed llm-calls)]
         [(eq? (cars-proposal-outcome proposal) 'backend-error)
          (failure-result generator trie 'backend-error
                          (or (cars-proposal-reason proposal) "backend failure")
                          started (sub1 attempt) rejected hard-invalid hard-proposals
                          threshold-rejections posterior-rejections weak-evaluations weak-cache-hits
                          proposed llm-calls)]
         [else
          (for ([update (in-list (cars-proposal-pending proposal))])
            (cars-node-install-domain! (pending-domain-node update)
                                       (pending-domain-domain update)
                                       (pending-domain-mass update)))
          (define terminal-node (cars-proposal-terminal-node proposal))
          (when terminal-node (cars-node-set-mass! terminal-node (cars-proposal-target-mass proposal)))
          (define decision (cars-proposal-decision proposal))
          (define hard? (and decision #t))
          (define evaluated? (and decision (cars-sampler-config-weak-model config) #t))
          (define cache-hit? (and decision (terminal-decision-cache-hit? decision)))
          (define next-hard-invalid (+ hard-invalid (if hard? 0 1)))
          (define next-hard-proposals (+ hard-proposals (if hard? 1 0)))
          (define next-threshold (+ threshold-rejections
                                    (if (eq? (cars-proposal-outcome proposal) 'threshold-rejected) 1 0)))
          (define next-posterior (+ posterior-rejections
                                    (if (eq? (cars-proposal-outcome proposal) 'posterior-rejected) 1 0)))
          (define next-evaluations (+ weak-evaluations (if (and evaluated? (not cache-hit?)) 1 0)))
          (define next-cache-hits (+ weak-cache-hits (if (and evaluated? cache-hit?) 1 0)))
          (define next-proposed (+ proposed (cars-proposal-proposed proposal)))
          (define next-llm (+ llm-calls (cars-proposal-llm-calls proposal)))
          (if (eq? (cars-proposal-outcome proposal) 'accepted)
              (let* ([weak-model (cars-sampler-config-weak-model config)]
                     [weak
                      (and weak-model decision
                           (let ([evaluation (terminal-decision-evaluation decision)])
                             (weak-result
                              (terminal-evaluation-observation evaluation)
                              (terminal-evaluation-posterior evaluation)
                              (cars-sampler-config-min-posterior config)
                              (terminal-evaluation-mass evaluation)
                              (terminal-decision-old-envelope decision)
                              (terminal-decision-accept-probability decision)
                              (terminal-decision-draw decision)
                              (weak-model-fingerprint weak-model)
                              (weak-model-schema-fingerprint weak-model))))]
                     [base (cars-proposal-base-logprob proposal)]
                     [target (+ base (if weak (log (weak-result-posterior weak)) 0.0))]
                     [ids (cars-proposal-ids proposal)])
                (generation-result
                 'found #f ids
                 (detokenize (model-tokenizer (generator-impl-model generator)) ids)
                 (guidance-value (cars-proposal-state proposal)) base target #t
                 (if weak 'exact-pwsg 'exact-hard)
                 (- (current-inexact-milliseconds) started)
                 (guidance-trace (cars-proposal-state proposal))
                 (and decision (terminal-evaluation-observation
                                (terminal-decision-evaluation decision)))
                 weak
                 (metrics generator trie attempt rejected next-hard-invalid next-hard-proposals
                          next-threshold next-posterior next-evaluations next-cache-hits
                          next-proposed next-llm)))
              (loop (add1 attempt) (add1 rejected) next-hard-invalid next-hard-proposals
                    next-threshold next-posterior next-evaluations next-cache-hits
                    next-proposed next-llm))])])))

(: generator-sample! (->* (Generator) (#:deadline-ms (Option Real)) generation-result))
(define (generator-sample! generator #:deadline-ms [deadline-ms #f])
  (when (unbox (generator-impl-closed? generator)) (error 'generator-sample! "generator is closed"))
  (unless (unbox (generator-impl-valid? generator)) (error 'generator-sample! "generator is invalid"))
  (when (unbox (generator-impl-busy? generator)) (error 'generator-sample! "generator is busy"))
  (set-box! (generator-impl-busy? generator) #t)
  (dynamic-wind void (lambda () (sample-cars generator deadline-ms))
                (lambda () (set-box! (generator-impl-busy? generator) #f))))

(: generator-sample-n! (->* (Generator Natural) (#:deadline-ms (Option Real))
                             (Listof generation-result)))
(define (generator-sample-n! generator count #:deadline-ms [deadline-ms #f])
  (for/list : (Listof generation-result) ([_i (in-range count)])
    (generator-sample! generator #:deadline-ms deadline-ms)))

(: generate
   (->* (Model String Program #:sampler Sampler)
        (#:temperature Real #:seed (Option Integer) #:deadline-ms (Option Real)
         #:max-tokens Natural)
        generation-result))
(define (generate model prompt program #:sampler sampler
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128])
  (define generator
    (make-generator model prompt program #:sampler sampler #:temperature temperature
                    #:seed seed #:max-tokens max-tokens))
  (dynamic-wind void
                (lambda () (generator-sample! generator #:deadline-ms deadline-ms))
                (lambda () (generator-close! generator))))
