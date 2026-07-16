#lang typed/racket/base

(require racket/list
         (only-in "private/model.rkt"
                  TokenId TokenIds Model Provider
                  tokenize detokenize token-ref vocab-size model-tokenizer model-provider
                  model-metadata model-close! model-acquire! model-release!
                  provider-vocab-size provider-eog-token-ids provider-start-session
                  provider-next-logits provider-factor-sampler
                  provider-commit-token! provider-end-session!)
         (only-in "private/regex.rkt"
                  RegexVocabulary make-regex-vocabulary parse-regex-program parse-ere-pattern)
         (only-in "private/guidance.rkt"
                  Program ControlRule Guidance GuidanceState
                  make-lit-program make-rx-program make-ere-program
                  make-choice-program make-seq-program make-repeat-program
                  make-text-program make-control-program
                  make-prefer-rule make-avoid-rule make-ban-rule
                  program-pwsg-errors program-layout-errors
                  program-schema-descriptors program-shape-form program-canonical-form
                  compile-guidance guidance-initial guidance-step guidance-token-domain
                  guidance-accepting? guidance-dead? guidance-weak-matches)
         (only-in "private/weak.rkt"
                  WeakSchema WeakObservation WeakModel token-span
                  weak-schema-fingerprint
                  weak-observation? weak-observation-labels weak-observation-rule-paths
                  weak-observation-polarities weak-observation-scope-spans
                  weak-observation-schema-fingerprint weak-observation-spec-fingerprint
                  weak-model? weak-model-fingerprint weak-model-schema-fingerprint
                  weak-model-diagnostics fingerprint-datum make-weak-schema make-weak-observation
                  fit-weak-model weak-posterior
                  save-weak-model load-weak-model)
         (only-in "private/sampling.rkt"
                  factor-selection? factor-selection-id factor-selection-base-probability
                  factor-selection-base-logprob factor-selection-frontier-mass
                  sample-factor-logits make-rng)
         (only-in "private/domain.rkt"
                  TokenDomain domain-only domain-union domain-subtract domain-member?)
         (only-in "private/cars.rkt"
                  CarsTrie CarsNode
                  make-cars-trie cars-trie-root cars-trie-node-count cars-trie-frozen?
                  cars-node-mass cars-node-domain-value cars-node-child-masses
                  cars-node-log-factor cars-node-child!
                  cars-node-install-domain! cars-node-set-mass!))

(provide Model model-metadata model-close!
         lit rx ere seq choice repeat text control prefer avoid ban validate-pwsg
         CompiledSpec compile-spec compiled-spec-close!
         WeakObservation weak-observation? weak-observation-labels
         weak-observation-rule-paths weak-observation-polarities
         weak-observation-scope-spans weak-observation-schema-fingerprint
         weak-observation-spec-fingerprint token-span
         WeakModel weak-model? weak-model-fingerprint weak-model-schema-fingerprint
         weak-model-diagnostics observe observe-token-ids observe-many fit-weak-model weak-posterior
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
(: seq (-> (Listof Program) Program))
(define (seq programs) (make-seq-program programs))
(: choice (-> (Listof Program) Program))
(define (choice programs) (make-choice-program programs))
(: repeat (-> Natural Natural Program Program))
(define (repeat min-count max-count program) (make-repeat-program min-count max-count program))
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
(: validate-pwsg (-> Program (Listof String)))
(define (validate-pwsg program) (program-pwsg-errors program))

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
   [trie-frozen? : Boolean]
   [weak-policy : Symbol])
  #:transparent)

(struct generation-result
  ([status : Symbol]
   [reason : (Option String)]
   [token-ids : TokenIds]
   [text : String]
   [lm-logprob : (Option Real)]
   [target-log-weight : (Option Real)]
   [hard-ok? : Boolean]
   [distribution-guarantee : Symbol]
   [latency-ms : Real]
   [tokenizer-fingerprint : String]
   [weak : (Option weak-result)]
   [metrics : generation-metrics])
  #:transparent)

;; Compile-once specification and observation --------------------------------

(struct compilation-context
  ([vocabulary : RegexVocabulary] [tokenizer-fingerprint : String]) #:transparent)
(define compilation-contexts : (Weak-HashTable Model compilation-context)
  (make-weak-hasheq))

(struct compiled-spec-impl
  ([model : Model] [program : Program] [guidance : Guidance] [schema : WeakSchema]
   [spec-fingerprint : String] [tokenizer-fingerprint : String]
   [has-weak-rules? : Boolean]
   [closed? : (Boxof Boolean)])
  #:transparent)
(define-type CompiledSpec compiled-spec-impl)

(: model-compilation-context (-> Model compilation-context))
(define (model-compilation-context model)
  (hash-ref
   compilation-contexts model
   (lambda ()
      (define tokenizer (model-tokenizer model))
      (define token-texts
        (for/vector : (Vectorof String) ([id : Natural (in-range (vocab-size tokenizer))])
          (token-ref tokenizer id)))
      (define context
        (compilation-context
         (make-regex-vocabulary token-texts)
         (fingerprint-datum
          (list 'rack-llm-tokenizer 1 (vector->list token-texts)))))
      (hash-set! compilation-contexts model context)
      context)))

(: compile-spec (-> Model Program CompiledSpec))
(define (compile-spec model program)
  (define errors (program-layout-errors program))
  (unless (null? errors) (error 'compile-spec "unsupported program layout: ~a" (car errors)))
  (model-acquire! model)
  (with-handlers ([exn:fail? (lambda ([exn : exn:fail]) (model-release! model) (raise exn))])
    (define context (model-compilation-context model))
    (define tokenizer (model-tokenizer model))
    (define canonical (program-canonical-form program))
    (define descriptors (program-schema-descriptors program))
    (compiled-spec-impl
     model program
     (compile-guidance program (lambda ([source : String]) (tokenize tokenizer source))
                       (compilation-context-vocabulary context))
     (make-weak-schema descriptors
                       (compilation-context-tokenizer-fingerprint context)
                       (program-shape-form program))
     (fingerprint-datum (list 'rack-llm-spec 3 canonical))
     (compilation-context-tokenizer-fingerprint context)
     (not (null? descriptors))
     (box #f))))

(: compiled-spec-close! (-> CompiledSpec Void))
(define (compiled-spec-close! compiled)
  (unless (unbox (compiled-spec-impl-closed? compiled))
    (set-box! (compiled-spec-impl-closed? compiled) #t)
    (model-release! (compiled-spec-impl-model compiled))))

(: check-compiled (-> Symbol CompiledSpec Void))
(define (check-compiled who compiled)
  (when (unbox (compiled-spec-impl-closed? compiled)) (error who "compiled spec is closed")))

(: observation-from-state (->* (CompiledSpec GuidanceState TokenIds) (#:trace? Boolean) WeakObservation))
(define (observation-from-state compiled state ids #:trace? [trace? #f])
  (make-weak-observation (compiled-spec-impl-schema compiled)
                         (program-canonical-form (compiled-spec-impl-program compiled))
                         (guidance-weak-matches state)
                         #:trace? trace? #:token-ids ids))

(: observe-token-ids (->* (CompiledSpec TokenIds) (#:trace? Boolean) WeakObservation))
(define (observe-token-ids compiled ids #:trace? [trace? #f])
  (check-compiled 'observe-token-ids compiled)
  (define program (compiled-spec-impl-program compiled))
  (define profile-errors (program-pwsg-errors program))
  (unless (null? profile-errors) (error 'observe-token-ids "unsupported PWSG program: ~a" (car profile-errors)))
  (define guidance (compiled-spec-impl-guidance compiled))
  (define state
    (for/fold ([state : GuidanceState (guidance-initial guidance)]) ([id (in-list ids)])
      (guidance-step guidance state id)))
  (unless (and (not (guidance-dead? state)) (guidance-accepting? state))
    (error 'observe-token-ids "candidate is not accepted by the hard program"))
  (observation-from-state compiled state ids #:trace? trace?))

(: observe (->* (CompiledSpec (U String generation-result)) (#:trace? Boolean) WeakObservation))
(define (observe compiled candidate #:trace? [trace? #f])
  (check-compiled 'observe compiled)
  (cond
    [(generation-result? candidate)
     (unless (string=? (compiled-spec-impl-tokenizer-fingerprint compiled)
                       (generation-result-tokenizer-fingerprint candidate))
       (error 'observe "generation result uses a different tokenizer"))
     (define weak (generation-result-weak candidate))
     (define existing (and weak (weak-result-observation weak)))
     (if (and existing
              (string=? (weak-observation-spec-fingerprint existing)
                        (compiled-spec-impl-spec-fingerprint compiled))
              (not trace?))
         existing
         (observe-token-ids compiled (generation-result-token-ids candidate) #:trace? trace?))]
    [else
     (define tokenizer (model-tokenizer (compiled-spec-impl-model compiled)))
     (define ids (tokenize tokenizer candidate))
     (unless (string=? candidate (detokenize tokenizer ids))
       (error 'observe "candidate does not round-trip through the model tokenizer; use observe-token-ids"))
     (observe-token-ids compiled ids #:trace? trace?)]))

(: observe-many (->* (CompiledSpec (Listof (U String generation-result TokenIds)))
                     (#:trace? Boolean) (Listof WeakObservation)))
(define (observe-many compiled candidates #:trace? [trace? #f])
  (for/list : (Listof WeakObservation) ([candidate (in-list candidates)])
    (if (list? candidate)
        (observe-token-ids compiled candidate #:trace? trace?)
        (observe compiled candidate #:trace? trace?))))

;; Generator -----------------------------------------------------------------

(struct cars-sampler-config
  ([max-attempts : Positive-Integer]
   [max-trie-nodes : (Option Natural)]
   [weak-model : (Option WeakModel)]
   [min-posterior : Real]
   [ignore-weak? : Boolean])
  #:transparent)
(define-type Sampler cars-sampler-config)

(: cars-sampler
   (->* (#:max-attempts Positive-Integer)
        (#:max-trie-nodes (Option Natural)
         #:weak-model (Option WeakModel)
         #:min-posterior Real
         #:ignore-weak? Boolean)
        Sampler))
(define (cars-sampler #:max-attempts max-attempts
                      #:max-trie-nodes [max-nodes #f]
                      #:weak-model [model #f]
                      #:min-posterior [min-posterior 0.0]
                      #:ignore-weak? [ignore-weak? #f])
  (when (and max-nodes (zero? max-nodes))
    (raise-argument-error 'cars-sampler "positive max-trie-nodes or #f" max-nodes))
  (unless (and (<= 0.0 min-posterior 1.0) (= min-posterior min-posterior))
    (raise-argument-error 'cars-sampler "real in [0,1]" min-posterior))
  (when (and (not model) (not (zero? min-posterior)))
    (error 'cars-sampler "min-posterior requires a weak model"))
  (when (and model ignore-weak?)
    (error 'cars-sampler "weak-model and ignore-weak? are mutually exclusive"))
  (cars-sampler-config max-attempts max-nodes model min-posterior ignore-weak?))

(struct terminal-evaluation
  ([observation : (Option WeakObservation)] [posterior : Real] [mass : Real])
  #:transparent)

(struct generator-impl
  ([model : Model]
   [provider : Provider]
   [compiled : CompiledSpec]
   [prompt-ids : TokenIds]
   [guidance : Guidance]
   [sampler : Sampler]
   [temperature : Real]
   [max-tokens : Natural]
   [rng : Pseudo-Random-Generator]
   [trie : CarsTrie]
   [terminal-cache : (HashTable CarsNode terminal-evaluation)]
   [weak-policy : Symbol]
   [closed? : (Boxof Boolean)]
   [busy? : (Boxof Boolean)]
   [valid? : (Boxof Boolean)])
  #:transparent)
(define-type Generator generator-impl)

(: make-generator
   (->* (CompiledSpec String #:sampler Sampler)
        (#:temperature Real #:max-tokens Natural #:seed (Option Integer))
        Generator))
(define (make-generator compiled prompt #:sampler sampler
                        #:temperature [temperature 0.7]
                        #:max-tokens [max-tokens 128]
                        #:seed [seed #f])
  (unless (and (> temperature 0.0) (= temperature temperature)
               (not (eqv? temperature +inf.0)))
    (raise-argument-error 'make-generator "finite positive temperature" temperature))
  (check-compiled 'make-generator compiled)
  (define model (compiled-spec-impl-model compiled))
  (define program (compiled-spec-impl-program compiled))
  (define weak-model (cars-sampler-config-weak-model sampler))
  (define has-weak-rules? (compiled-spec-impl-has-weak-rules? compiled))
  (define ignore-weak? (cars-sampler-config-ignore-weak? sampler))
  (when (and has-weak-rules? (not weak-model) (not ignore-weak?))
    (error 'make-generator
           "weak-model-required: program contains prefer/avoid rules; provide a weak model or set #:ignore-weak? #t"))
  (when (and weak-model (not has-weak-rules?))
    (error 'make-generator "weak model requires a program with prefer/avoid rules"))
  (define weak-policy
    (cond [weak-model 'applied]
          [(and has-weak-rules? ignore-weak?) 'ignored-explicitly]
          [else 'not-present]))
  (when weak-model
    (define profile-errors (program-pwsg-errors program))
    (unless (null? profile-errors)
      (error 'make-generator "unsupported PWSG program: ~a" (car profile-errors)))
    (unless (string=? (weak-model-schema-fingerprint weak-model)
                      (weak-schema-fingerprint (compiled-spec-impl-schema compiled)))
      (error 'make-generator "incompatible weak model and program schema")))
  (model-acquire! model)
  (with-handlers ([exn:fail? (lambda ([exn : exn:fail])
                               (model-release! model)
                               (raise exn))])
    (generator-impl model (model-provider model) compiled
                    (tokenize (model-tokenizer model) prompt)
                    (compiled-spec-impl-guidance compiled)
                    sampler temperature max-tokens (make-rng seed)
                    (make-cars-trie (cars-sampler-config-max-trie-nodes sampler))
                    (make-hasheq) weak-policy (box #f) (box #f) (box #t))))

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

(: evaluate-terminal
   (-> Generator TokenIds GuidanceState (Option CarsNode)
       (Values terminal-evaluation Boolean)))
(define (evaluate-terminal generator ids state prefix-node)
  (define config (generator-impl-sampler generator))
  (define model (cars-sampler-config-weak-model config))
  (cond
    [(not model) (values (terminal-evaluation #f 1.0 1.0) #f)]
    [else
     (define cached (and prefix-node
                         (hash-ref (generator-impl-terminal-cache generator) prefix-node #f)))
     (if cached
         (values cached #t)
         (let* ([observation
                 (observation-from-state (generator-impl-compiled generator) state ids)]
                [posterior (weak-posterior model observation)]
                [mass (if (>= posterior (cars-sampler-config-min-posterior config)) posterior 0.0)]
                [evaluation (terminal-evaluation observation posterior mass)])
           (when prefix-node
             (hash-set! (generator-impl-terminal-cache generator) prefix-node evaluation))
           (values evaluation #f)))]))

(: decide-terminal
   (-> Generator TokenIds GuidanceState Real Natural Natural
       (Listof pending-domain) (Option CarsNode) (Option CarsNode) cars-proposal))
(define (decide-terminal generator ids state base-logprob proposed llm-calls pending prefix-node node)
  (define-values (evaluation cache-hit?) (evaluate-terminal generator ids state prefix-node))
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
                                 [reversed-ids : TokenIds '()]
                                 [state : GuidanceState
                                  (guidance-initial guidance #:weak? (and (cars-sampler-config-weak-model
                                                                          (generator-impl-sampler generator))
                                                                         #t))]
                                 [node : (Option CarsNode) (cars-trie-root trie)]
                                 [base : Real 0.0]
                                 [proposed : Natural 0]
                                 [llm-calls : Natural 0]
                                 [pending : (Listof pending-domain) '()])
        (cond
          [(>= depth (generator-impl-max-tokens generator))
           (define child (and node (cars-node-child! trie node vocab 1.0)))
           (define ids (reverse reversed-ids))
           (if (guidance-accepting? state)
               (decide-terminal generator ids state base proposed llm-calls pending node child)
               (cars-proposal 'hard-invalid ids state base proposed llm-calls pending child 0.0 #f
                              "virtual STOP is hard-invalid"))]
          [else
           (define domain
             (or (and node (cars-node-domain-value node))
                 (let* ([content (domain-subtract (guidance-token-domain guidance state)
                                                  (domain-only eog-ids))]
                        [stops (if (guidance-accepting? state)
                                   (domain-only eog-ids) (domain-only '()))])
                   (domain-union content stops))))
           (define native-sample (provider-factor-sampler provider))
           (define selection
             (if native-sample
                 (native-sample
                  session (generator-impl-temperature generator) domain
                  (and node (cars-node-domain-value node) #t)
                  (if node (cars-node-child-masses node) '())
                  (parameterize ([current-pseudo-random-generator (generator-impl-rng generator)])
                    (random)))
                 (sample-factor-logits
                  (provider-next-logits provider session)
                  (generator-impl-rng generator)
                  (generator-impl-temperature generator)
                  (if node (lambda ([id : TokenId]) (cars-node-log-factor node id))
                      (lambda ([_id : TokenId]) 0.0))
                  (lambda ([id : TokenId]) (domain-member? domain id)))))
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
              (define ids (reverse reversed-ids))
              (if (guidance-accepting? state)
                  (decide-terminal generator ids state next-base proposed (add1 llm-calls)
                                   next-pending node child)
                  (cars-proposal 'hard-invalid ids state next-base proposed (add1 llm-calls)
                                 next-pending child 0.0 #f "EOG is hard-invalid"))]
             [else
              (define next-state (guidance-step guidance state id))
              (define next-reversed (cons id reversed-ids))
              (if (guidance-dead? next-state)
                  (cars-proposal 'hard-invalid (reverse next-reversed) next-state next-base
                                 (add1 proposed) (add1 llm-calls) next-pending child 0.0 #f
                                 "content token made the hard state dead")
                  (begin
                    (provider-commit-token! provider session id)
                    (loop (add1 depth) next-reversed next-state child next-base
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
                      (cars-trie-frozen? trie)
                      (generator-impl-weak-policy generator)))

(: failure-result
   (-> Generator CarsTrie Symbol String Real Natural Natural Natural Natural Natural Natural Natural Natural Natural Natural
       generation-result))
(define (failure-result generator trie status reason started attempts rejected hard-invalid hard-proposals
                        threshold-rejections posterior-rejections weak-evaluations weak-cache-hits proposed llm-calls)
  (generation-result status reason '() "" #f #f #f 'no-sample
                     (- (current-inexact-milliseconds) started)
                     (compiled-spec-impl-tokenizer-fingerprint
                      (generator-impl-compiled generator))
                     #f
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
                            (cars-proposal 'backend-error '()
                                           (guidance-initial
                                            (generator-impl-guidance generator)
                                            #:weak? (and (cars-sampler-config-weak-model config) #t))
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
                              (assert (terminal-evaluation-observation evaluation)
                                      weak-observation?)
                              (terminal-evaluation-posterior evaluation)
                              (cars-sampler-config-min-posterior config)
                              (terminal-evaluation-mass evaluation)
                              (terminal-decision-old-envelope decision)
                              (terminal-decision-accept-probability decision)
                              (terminal-decision-draw decision)
                              (weak-model-fingerprint weak-model)
                              (weak-model-schema-fingerprint weak-model))))]
                     [base (cars-proposal-base-logprob proposal)]
                     [target (assert
                              (+ base (if weak (log (weak-result-posterior weak)) 0.0))
                              real?)]
                     [ids (cars-proposal-ids proposal)])
                (generation-result
                 'found #f ids
                 (detokenize (model-tokenizer (generator-impl-model generator)) ids)
                 base target #t
                 (if weak 'exact-pwsg 'exact-hard)
                 (- (current-inexact-milliseconds) started)
                 (compiled-spec-impl-tokenizer-fingerprint
                  (generator-impl-compiled generator))
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
   (->* (CompiledSpec String #:sampler Sampler)
        (#:temperature Real #:seed (Option Integer) #:deadline-ms (Option Real)
         #:max-tokens Natural)
        generation-result))
(define (generate compiled prompt #:sampler sampler
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128])
  (define generator
    (make-generator compiled prompt #:sampler sampler #:temperature temperature
                    #:seed seed #:max-tokens max-tokens))
  (dynamic-wind void
                (lambda () (generator-sample! generator #:deadline-ms deadline-ms))
                (lambda () (generator-close! generator))))
