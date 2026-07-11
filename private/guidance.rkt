#lang typed/racket/base

(require racket/list
         (only-in "logits.rkt" LogitsView logits-ref)
         (only-in "sampling.rkt"
                  scored-selection-index
                  token-sampling-selection-id
                  token-sampling-selection-lm-logprob
                  token-sampling-selection-dead-count
                  token-sampling-selection-candidate-count
                  sample-logits-with-deltas
                  sample-masked-logits
                  sample-scored-index
                  logit-logprob
                  logits-log-z)
         (only-in "regex.rkt"
                  RegexMachine
                  RegexProgram
                  RegexState
                  RegexVocabulary
                  instantiate-regex-machine
                  regex-accepting?
                  regex-accepted-ids
                  regex-allowed-ids
                  regex-initial
                  regex-step
                  regex-terminal?))

(provide Score
         Program
         TextObserver
         Guidance
         GuidanceState
         neg-inf
         log-score-add
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
         guidance-initial
         guidance-step
         guidance-allowed-token-ids
         (struct-out guidance-step-selection)
         (struct-out guidance-step-failure)
         guidance-select-step
         guidance-accepting?
         guidance-budget-accepting?
         guidance-terminal?
         guidance-dead?
         guidance-score
         guidance-accepted-score
         guidance-potential
         guidance-value
         guidance-token-ids
         guidance-trace)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
(define-type TokenizeProc (-> String TokenIds))
(define-type Score Real)
(define neg-inf : Real -inf.0)

(struct %lit-program ([ids : TokenIds]) #:transparent)
(struct %rx-program ([machine : RegexMachine]) #:transparent)
(struct %pure-program ([value : Any]) #:transparent)
(struct (A) %choice-program ([options : (Listof A)]) #:transparent)
(struct (A) %seq-program ([children : (Listof A)]) #:transparent)
(struct (A) %repeat-program ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct (A) %bind-program ([first : A] [continue : (-> Any A)]) #:transparent)
(struct (A) %score-program ([score : Real] [child : A]) #:transparent)
(struct %text-guidance ([max-tokens : Natural] [observers : (Listof CompiledTextObserver)]) #:transparent)

(define-type Guidance
  (Rec F (U %lit-program
            %rx-program
            %pure-program
            (%choice-program F)
            (%seq-program F)
            (%repeat-program F)
            (%bind-program F)
            (%score-program F)
            %text-guidance)))

(struct compiled-rank-observer ([score : Real] [ids : TokenIds]) #:transparent)
(struct compiled-ban-observer ([ids : TokenIds]) #:transparent)
(struct rx-compiled-rank-observer
  ([score : Real]
   [machine : RegexMachine]
   [token-ids : TokenIds])
  #:transparent)
(struct rx-compiled-ban-observer
  ([machine : RegexMachine]
   [token-ids : TokenIds])
  #:transparent)
(struct weighted-rule ([score : Real] [ids : TokenIds] [source : String]) #:transparent)
(struct compiled-weighted-observer ([rules : (Listof weighted-rule)]) #:transparent)
(define-type CompiledTextObserver (U compiled-rank-observer compiled-ban-observer rx-compiled-rank-observer rx-compiled-ban-observer compiled-weighted-observer))

(struct program
  ([compile : (-> TokenizeProc RegexVocabulary Guidance)]
   [score-ceiling : (Option Real)]
   [dynamic? : Boolean])
  #:transparent)
(define-type Program program)

(struct text-observer
  ([compile : (-> TokenizeProc RegexVocabulary CompiledTextObserver)]
   [score-ceiling : Real])
  #:transparent)
(define-type TextObserver text-observer)

(struct weighted-source-rule ([score : Real] [source : String]) #:transparent)

(: compile-guidance (-> Program TokenizeProc RegexVocabulary Guidance))
(define (compile-guidance program tokenize-text vocabulary)
  ((program-compile program) tokenize-text vocabulary))

(: compile-text-observer (-> TextObserver TokenizeProc RegexVocabulary CompiledTextObserver))
(define (compile-text-observer observer tokenize-text vocabulary)
  ((text-observer-compile observer) tokenize-text vocabulary))

(: finite-score (-> Symbol Real Real))
(define (finite-score who value)
  (unless (and (not (eqv? value +inf.0))
               (not (eqv? value -inf.0))
               (= value value))
    (raise-argument-error who "finite real score" value))
  value)

(: ceilings-sum (-> (Listof (Option Real)) (Option Real)))
(define (ceilings-sum ceilings)
  (and (andmap real? ceilings)
       (for/sum : Real ([ceiling (in-list ceilings)])
         (assert ceiling real?))))

(: ceilings-max (-> (Listof (Option Real)) (Option Real)))
(define (ceilings-max ceilings)
  (and (pair? ceilings)
       (andmap real? ceilings)
       (apply max (map (lambda ([ceiling : (Option Real)]) (assert ceiling real?)) ceilings))))

(: make-lit-program (-> String Program))
(define (make-lit-program source)
  (program (lambda ([tokenize-text : TokenizeProc] [_vocabulary : RegexVocabulary])
             (%lit-program (tokenize-text source)))
           0.0 #f))

(: make-rx-program (-> RegexProgram Program))
(define (make-rx-program regex-program)
  (program (lambda ([_tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%rx-program (instantiate-regex-machine regex-program vocabulary)))
           0.0 #f))

(: make-pure-program (-> Any Program))
(define (make-pure-program value)
  (program (lambda ([_tokenize-text : TokenizeProc] [_vocabulary : RegexVocabulary])
             (%pure-program value))
           0.0 #f))

(: make-choice-program (-> (Listof Program) Program))
(define (make-choice-program options)
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%choice-program
              (for/list : (Listof Guidance) ([option (in-list options)])
                (compile-guidance option tokenize-text vocabulary))))
           (ceilings-max (map program-score-ceiling options))
           (ormap program-dynamic? options)))

(: make-seq-program (-> (Listof Program) Program))
(define (make-seq-program children)
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%seq-program
              (for/list : (Listof Guidance) ([child (in-list children)])
                (compile-guidance child tokenize-text vocabulary))))
           (ceilings-sum (map program-score-ceiling children))
           (ormap program-dynamic? children)))

(: make-repeat-program (-> Natural Natural Program Program))
(define (make-repeat-program min-count max-count item)
  (when (> min-count max-count)
    (raise-arguments-error 'repeat "minimum exceeds maximum"
                           "minimum" min-count "maximum" max-count))
  (define item-ceiling (program-score-ceiling item))
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (define compiled (compile-guidance item tokenize-text vocabulary))
             (when (guidance-accepting? (guidance-initial compiled))
               (error 'repeat "nullable repeated programs are unsupported"))
             (%repeat-program min-count max-count compiled))
           (and item-ceiling
                (max (* min-count item-ceiling) (* max-count item-ceiling)))
           (program-dynamic? item)))

(: make-bind-program (-> Program (-> Any Program) Program))
(define (make-bind-program first continue)
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%bind-program
              (compile-guidance first tokenize-text vocabulary)
              (lambda ([value : Any])
                (compile-guidance (continue value) tokenize-text vocabulary))))
           #f #t))

(: make-score-program (-> Real Program Program))
(define (make-score-program amount child)
  (define score* (finite-score 'score amount))
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%score-program score* (compile-guidance child tokenize-text vocabulary)))
           (and (program-score-ceiling child)
                (+ score* (assert (program-score-ceiling child) real?)))
           (program-dynamic? child)))

(: make-text-program (-> Natural (Listof TextObserver) Program))
(define (make-text-program max-tokens observers)
  (program (lambda ([tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
             (%text-guidance
              max-tokens
              (for/list : (Listof CompiledTextObserver)
                        ([observer (in-list observers)])
                (compile-text-observer observer tokenize-text vocabulary))))
           (for/sum : Real ([observer (in-list observers)])
             (text-observer-score-ceiling observer))
           #f))

(: make-rank-observer (-> Real String TextObserver))
(define (make-rank-observer amount source)
  (define score* (finite-score 'rank amount))
  (text-observer (lambda ([tokenize-text : TokenizeProc] [_vocabulary : RegexVocabulary])
                   (compiled-rank-observer score* (tokenize-text source)))
                 (max 0.0 score*)))

(: make-ban-observer (-> String TextObserver))
(define (make-ban-observer source)
  (text-observer (lambda ([tokenize-text : TokenizeProc] [_vocabulary : RegexVocabulary])
                   (compiled-ban-observer (tokenize-text source)))
                 0.0))

(: make-rx-rank-observer (-> Real RegexProgram TextObserver))
(define (make-rx-rank-observer amount regex-program)
  (define score* (finite-score 'rank-rx amount))
  (text-observer
   (lambda ([_tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
     (define machine (instantiate-regex-machine regex-program vocabulary))
     (rx-compiled-rank-observer
      score* machine (regex-accepted-ids machine (regex-initial machine))))
   (max 0.0 score*)))

(: make-rx-ban-observer (-> RegexProgram TextObserver))
(define (make-rx-ban-observer regex-program)
  (text-observer
   (lambda ([_tokenize-text : TokenizeProc] [vocabulary : RegexVocabulary])
     (define machine (instantiate-regex-machine regex-program vocabulary))
     (rx-compiled-ban-observer
      machine (regex-accepted-ids machine (regex-initial machine))))
   0.0))

(: make-weighted-rule (-> Real String weighted-source-rule))
(define (make-weighted-rule amount source)
  (weighted-source-rule (finite-score 'weight amount) source))

(: make-weighted-observer (-> (Listof weighted-source-rule) TextObserver))
(define (make-weighted-observer rules)
  (text-observer
   (lambda ([tokenize-text : TokenizeProc] [_vocabulary : RegexVocabulary])
     (compiled-weighted-observer
      (for/list : (Listof weighted-rule)
                ([rule (in-list rules)])
        (weighted-rule (weighted-source-rule-score rule)
                       (tokenize-text (weighted-source-rule-source rule))
                       (weighted-source-rule-source rule)))))
   (for/sum : Real ([rule (in-list rules)])
     (max 0.0 (weighted-source-rule-score rule)))))

(struct lit-state ([pos : Natural] [len : Natural]) #:transparent)
(struct rx-state ([state : RegexState] [accepting? : Boolean]) #:transparent)
(struct pure-state ([value : Any]) #:transparent)
(struct (A) choice-state ([children : (Listof A)]) #:transparent)
(struct (A) seq-state
  ([index : Natural]
   [len : Natural]
   [child : A]
   [score : Real]
   [value : Any]
   [ids : TokenIds])
  #:transparent)
(struct (A) repeat-state
  ([count : Natural]
   [min-count : Natural]
   [max-count : Natural]
   [child : A]
   [values : (Listof Any)]
   [score : Real]
   [ids : TokenIds])
  #:transparent)
(struct (A) bind-state
  ([phase : Symbol]
   [child : A]
   [score : Real]
   [cont-guidance : (Option Guidance)]
   [ids : TokenIds])
  #:transparent)
(struct (A) score-state ([score : Real] [child : A]) #:transparent)
(struct text-state ([ids : TokenIds] [max-tokens : Natural] [observer-states : (Listof observer-state)]) #:transparent)
(struct dead-state ([ids : TokenIds] [trace : (Listof Any)]) #:transparent)

(define-type GuidanceState
  (Rec S (U lit-state
            rx-state
            pure-state
            (choice-state S)
            (seq-state S)
            (repeat-state S)
            (bind-state S)
            (score-state S)
            text-state
            dead-state)))

(struct observer-state
  ([observer : CompiledTextObserver]
   [ids : TokenIds]
   [matched? : Boolean]
   [dead? : Boolean]
   [score : Real]
   [potential : Real]
   [trace : (Listof Any)])
  #:transparent)

(struct segment-candidate
  ([ids : TokenIds]
   [state : GuidanceState]
   [score-delta : Real]
   [potential-delta : Real])
  #:transparent)

(struct guidance-step-selection
  ([ids : TokenIds]
   [state : GuidanceState]
   [lm-logprob : (Option Real)]
   [llm-calls : Natural]
   [dead-count : Natural]
   [candidate-count : Natural])
  #:transparent)

(struct guidance-step-failure
  ([status : Symbol]
   [reason : String])
  #:transparent)

(define-type CurrentLogits (-> LogitsView))
(define-type ScoreSegment (-> TokenIds Real))
(define-type GuidanceStepResult (U guidance-step-selection guidance-step-failure))

(: log-score-dead? (-> Real Boolean))
(define (log-score-dead? x) (eqv? x neg-inf))

(: log-score-add (-> Real Real Real))
(define (log-score-add a b)
  (if (or (log-score-dead? a) (log-score-dead? b)) neg-inf (+ a b)))

(: guidance-initial (-> Guidance GuidanceState))
(define (guidance-initial f)
  (normalize
   f
   (cond
     [(%lit-program? f) (lit-state 0 (length (%lit-program-ids f)))]
     [(%rx-program? f)
      (define initial-rx-state (regex-initial (%rx-program-machine f)))
      (rx-state initial-rx-state
                (regex-accepting? (%rx-program-machine f) initial-rx-state))]
     [(%pure-program? f) (pure-state (%pure-program-value f))]
     [(%choice-program? f)
      (choice-state (map guidance-initial (%choice-program-options f)))]
     [(%seq-program? f)
      (define children (%seq-program-children f))
      (seq-state 0
                 (length children)
                 (if (null? children) (pure-state (void)) (guidance-initial (car children)))
                 0.0
                 (void)
                 '())]
     [(%repeat-program? f)
      (repeat-state 0
                    (%repeat-program-min-count f)
                    (%repeat-program-max-count f)
                    (guidance-initial (%repeat-program-item f))
                    '()
                    0.0
                    '())]
     [(%bind-program? f)
      (bind-state 'first
                  (guidance-initial (%bind-program-first f))
                  0.0
                  #f
                  '())]
     [(%score-program? f)
      (score-state (%score-program-score f)
                   (guidance-initial (%score-program-child f)))]
     [(%text-guidance? f)
      (text-state '()
                  (%text-guidance-max-tokens f)
                  (map observer-initial (%text-guidance-observers f)))])))

(: guidance-step (-> Guidance GuidanceState TokenId GuidanceState))
(define (guidance-step f st id)
  (if (guidance-dead? st)
      st
      (let ([next (step-raw f st id)])
        (if (dead-state? next) next (normalize f next)))))

(: step-raw (-> Guidance GuidanceState TokenId GuidanceState))
(define (step-raw f st id)
  (cond
    [(%lit-program? f)
     (define s (assert-lit-state st))
     (if (and (< (lit-state-pos s) (length (%lit-program-ids f)))
              (= id (list-ref (%lit-program-ids f) (lit-state-pos s))))
         (lit-state (add1 (lit-state-pos s)) (lit-state-len s))
         (dead-state (list id) (list 'lit-dead)))]
    [(%rx-program? f)
     (define s (assert-rx-state st))
     (define next (regex-step (%rx-program-machine f) (rx-state-state s) id))
     (if next
         (rx-state next
                   (regex-accepting? (%rx-program-machine f) next))
         (dead-state (list id) (list 'rx-dead)))]
    [(%pure-program? f) (dead-state (list id) (list 'pure-terminal))]
    [(%choice-program? f)
     (define s (assert-choice-state st))
     (choice-state
      (for/list : (Listof GuidanceState)
                ([child (in-list (%choice-program-options f))]
                 [child-state (in-list (choice-state-children s))])
        (guidance-step child child-state id)))]
    [(%seq-program? f)
     (define s (assert-seq-state st))
     (define child-filter (list-ref (%seq-program-children f) (seq-state-index s)))
     (seq-state (seq-state-index s)
                (seq-state-len s)
                (guidance-step child-filter (seq-state-child s) id)
                (seq-state-score s)
                (seq-state-value s)
                (append (seq-state-ids s) (list id)))]
    [(%repeat-program? f)
     (define s (assert-repeat-state st))
     (if (>= (repeat-state-count s) (%repeat-program-max-count f))
         (dead-state (append (repeat-state-ids s) (list id)) (list 'repeat-max))
         (repeat-state (repeat-state-count s)
                       (repeat-state-min-count s)
                       (repeat-state-max-count s)
                       (guidance-step (%repeat-program-item f) (repeat-state-child s) id)
                       (repeat-state-values s)
                       (repeat-state-score s)
                       (append (repeat-state-ids s) (list id))))]
    [(%bind-program? f)
     (define s (assert-bind-state st))
     (define active-filter
       (if (eq? (bind-state-phase s) 'first)
           (%bind-program-first f)
           (assert (bind-state-cont-guidance s) values)))
     (bind-state (bind-state-phase s)
                 (guidance-step active-filter (bind-state-child s) id)
                 (bind-state-score s)
                 (bind-state-cont-guidance s)
                 (append (bind-state-ids s) (list id)))]
    [(%score-program? f)
     (define s (assert-score-state st))
     (score-state (score-state-score s)
                  (guidance-step (%score-program-child f) (score-state-child s) id))]
    [(%text-guidance? f)
     (define s (assert-text-state st))
     (text-state (append (text-state-ids s) (list id))
                 (text-state-max-tokens s)
                 (map (lambda ([ws : observer-state]) (observer-step ws id))
                      (text-state-observer-states s)))]))

(: normalize (-> Guidance GuidanceState GuidanceState))
(define (normalize f st)
  (cond
    [(%seq-program? f) (normalize-seq f (assert-seq-state st))]
    [(%repeat-program? f) (normalize-repeat f (assert-repeat-state st))]
    [(%bind-program? f) (normalize-bind f (assert-bind-state st))]
    [(%score-program? f) (normalize-score f (assert-score-state st))]
    [else st]))

(: normalize-seq (-> (%seq-program Guidance) (seq-state GuidanceState) GuidanceState))
(define (normalize-seq f st0)
  (let loop : GuidanceState ([st : (seq-state GuidanceState) st0])
    (define children (%seq-program-children f))
    (cond
      [(null? children) st]
      [(guidance-dead? (seq-state-child st))
       (dead-state (seq-state-ids st) (guidance-trace (seq-state-child st)))]
      [(guidance-accepting? (seq-state-child st))
       (define child-state (seq-state-child st))
       (define next-score (log-score-add (seq-state-score st) (guidance-score child-state)))
       (define next-value (guidance-value child-state))
       (define next-index (add1 (seq-state-index st)))
       (if (>= next-index (length children))
           (seq-state next-index
                      (seq-state-len st)
                      child-state
                      next-score
                      next-value
                      (seq-state-ids st))
           (loop (seq-state next-index
                            (seq-state-len st)
                            (guidance-initial (list-ref children next-index))
                            next-score
                            next-value
                            (seq-state-ids st))))]
      [else st])))

(: normalize-repeat (-> (%repeat-program Guidance) (repeat-state GuidanceState) GuidanceState))
(define (normalize-repeat f st0)
  (let loop : GuidanceState ([st : (repeat-state GuidanceState) st0])
    (define child-state (repeat-state-child st))
    (cond
      [(guidance-dead? child-state)
       ;; Once a token starts another repetition it cannot be silently
       ;; reinterpreted as stopping the repeat. Stopping is an epsilon/STOP
       ;; decision at the previous accepting boundary.
       (dead-state (repeat-state-ids st) (guidance-trace child-state))]
      [(and (guidance-accepting? child-state)
            (< (repeat-state-count st) (repeat-state-max-count st)))
       (define next-count (add1 (repeat-state-count st)))
       (define next-values (cons (guidance-value child-state) (repeat-state-values st)))
       (define next-score (log-score-add (repeat-state-score st) (guidance-score child-state)))
       (if (= next-count (repeat-state-max-count st))
           (repeat-state next-count
                         (repeat-state-min-count st)
                         (repeat-state-max-count st)
                         child-state
                         next-values
                         next-score
                         (repeat-state-ids st))
           (loop (repeat-state next-count
                               (repeat-state-min-count st)
                               (repeat-state-max-count st)
                               (guidance-initial (%repeat-program-item f))
                               next-values
                               next-score
                               (repeat-state-ids st))))]
      [else st])))

(: normalize-bind (-> (%bind-program Guidance) (bind-state GuidanceState) GuidanceState))
(define (normalize-bind f st)
  (define child-state (bind-state-child st))
  (cond
    [(guidance-dead? child-state) (dead-state (bind-state-ids st) (guidance-trace child-state))]
    [(and (eq? (bind-state-phase st) 'first) (guidance-accepting? child-state))
     (define next-filter ((%bind-program-continue f) (guidance-value child-state)))
     (normalize-bind f
                     (bind-state 'cont
                                 (guidance-initial next-filter)
                                 (guidance-score child-state)
                                 next-filter
                                 (bind-state-ids st)))]
    [else st]))

(: normalize-score (-> (%score-program Guidance) (score-state GuidanceState) GuidanceState))
(define (normalize-score _f st) st)

(: guidance-select-step
   (-> Guidance GuidanceState Natural Natural CurrentLogits ScoreSegment Real Real Real
       Pseudo-Random-Generator GuidanceStepResult))
(define (guidance-select-step f st remaining-budget vocab-size current-logits score-segment
                              beta lambda-weight temperature rng)
  (cond
    [(zero? remaining-budget)
     (guidance-step-failure 'not-found-budget "token budget exhausted before next guidance segment")]
    [(and (%rx-program? f) (rx-state? st))
     (select-rx-token f st current-logits temperature rng)]
    [(and (%text-guidance? f)
          (text-state? st)
          (text-fast-supported? (text-state-observer-states st)))
     (select-text-token f st current-logits beta lambda-weight temperature rng)]
    [else
     (select-segment-fallback f st remaining-budget vocab-size current-logits score-segment
                              beta lambda-weight temperature rng)]))

(: select-rx-token
   (-> Guidance GuidanceState CurrentLogits Real Pseudo-Random-Generator
       GuidanceStepResult))
(define (select-rx-token f st current-logits temperature rng)
  (define program (assert f %rx-program?))
  (define rx-st (assert-rx-state st))
  (define allowed
    (regex-allowed-ids (%rx-program-machine program) (rx-state-state rx-st)))
  (cond
    [(null? allowed)
     (guidance-step-failure 'not-found-hard "no provider token keeps the regex valid")]
    [(null? (cdr allowed))
     (define id (car allowed))
     (guidance-step-selection (list id) (guidance-step f st id) #f 0 0 1)]
    [else
     (define logits (current-logits))
     (define selected (sample-masked-logits logits allowed rng temperature))
     (unless selected (error 'guidance-select-step "no sampleable regex token"))
     (define selected* (assert selected values))
     (define id (token-sampling-selection-id selected*))
     (guidance-step-selection
      (list id)
      (guidance-step f st id)
      (token-sampling-selection-lm-logprob selected*)
      1
      (token-sampling-selection-dead-count selected*)
      (token-sampling-selection-candidate-count selected*))]))

(: select-segment-fallback
   (-> Guidance GuidanceState Natural Natural CurrentLogits ScoreSegment Real Real Real
       Pseudo-Random-Generator GuidanceStepResult))
(define (select-segment-fallback f st remaining-budget vocab-size current-logits score-segment
                                 beta lambda-weight temperature rng)
  (define raw-candidates (guidance-segment-candidates f st vocab-size))
  (define candidates
    (filter (lambda ([candidate : segment-candidate])
              (<= (length (segment-candidate-ids candidate)) remaining-budget))
            raw-candidates))
  (define candidate-count (length candidates))
  (cond
    [(zero? candidate-count)
     (if (null? raw-candidates)
         (guidance-step-failure 'not-found-hard "no provider segment keeps the guidance valid")
         (guidance-step-failure 'not-found-budget "token budget exhausted before next guidance segment"))]
    [else
     (define-values (candidate llm-calls lm-logprob)
       (choose-segment-candidate candidates current-logits score-segment
                                 beta lambda-weight temperature rng))
     (guidance-step-selection (segment-candidate-ids candidate)
                              (segment-candidate-state candidate)
                              lm-logprob
                              llm-calls
                              0
                              candidate-count)]))

(: choose-segment-candidate
   (-> (Listof segment-candidate) CurrentLogits ScoreSegment Real Real Real
       Pseudo-Random-Generator
       (Values segment-candidate Natural (Option Real))))
(define (choose-segment-candidate candidates current-logits score-segment
                                  beta lambda-weight temperature rng)
  (cond
    [(null? (cdr candidates)) (values (car candidates) 0 #f)]
    [(andmap single-token-candidate? candidates)
     (define logits (current-logits))
     (define log-z (logits-log-z logits))
     (define weights : (Vectorof Real) (make-vector (length candidates) neg-inf))
     (for ([candidate (in-list candidates)]
           [i : Natural (in-naturals)])
       (define id (car (segment-candidate-ids candidate)))
       (define local-delta
         (+ (segment-candidate-score-delta candidate)
            (* lambda-weight (segment-candidate-potential-delta candidate))))
       (vector-set! weights i
                    (+ (logit-logprob (logits-ref logits id) log-z)
                       (* beta local-delta))))
     (define selected (sample-scored-index weights rng temperature))
     (unless selected
       (error 'guidance-select-step "no sampleable segment"))
     (define selected* (assert selected values))
     (define selected-index (scored-selection-index selected*))
     (define selected-candidate (list-ref candidates selected-index))
     (define selected-id (car (segment-candidate-ids selected-candidate)))
     (values selected-candidate
             1
             (logit-logprob (logits-ref logits selected-id) log-z))]
    [else
     (define weights : (Vectorof Real) (make-vector (length candidates) neg-inf))
     (define segment-scores : (Vectorof Real) (make-vector (length candidates) neg-inf))
     (define llm-calls : Natural 0)
     (for ([candidate (in-list candidates)]
           [i : Natural (in-naturals)])
       (define ids (segment-candidate-ids candidate))
       (define lm-score (score-segment ids))
       (vector-set! segment-scores i lm-score)
       (set! llm-calls (+ llm-calls (length ids)))
       (define local-delta
         (+ (segment-candidate-score-delta candidate)
            (* lambda-weight (segment-candidate-potential-delta candidate))))
       (vector-set! weights i (+ lm-score (* beta local-delta))))
     (define selected (sample-scored-index weights rng temperature))
     (unless selected
       (error 'guidance-select-step "no sampleable segment"))
     (define selected* (assert selected values))
     (define selected-index (scored-selection-index selected*))
     (values (list-ref candidates selected-index)
             llm-calls
             (vector-ref segment-scores selected-index))]))

(: single-token-candidate? (-> segment-candidate Boolean))
(define (single-token-candidate? candidate)
  (define ids (segment-candidate-ids candidate))
  (and (pair? ids) (null? (cdr ids))))

(: select-text-token
   (-> Guidance GuidanceState CurrentLogits Real Real Real Pseudo-Random-Generator
       GuidanceStepResult))
(define (select-text-token f st current-logits beta lambda-weight temperature rng)
  (define text-st (assert-text-state st))
  (define logits (current-logits))
  (define token-delta (make-text-token-delta (text-state-observer-states text-st)
                                             lambda-weight))
  (define selected (sample-logits-with-deltas logits rng temperature beta token-delta))
  (cond
    [(not selected)
     (guidance-step-failure 'not-found-hard "no provider token keeps the guidance valid")]
    [else
     (define selected* (assert selected values))
     (define id (token-sampling-selection-id selected*))
     (define next-state (guidance-step f st id))
     (if (guidance-dead? next-state)
         (guidance-step-failure 'not-found-hard "selected token made guidance dead")
         (guidance-step-selection
          (list id)
          next-state
          (token-sampling-selection-lm-logprob selected*)
          1
          (token-sampling-selection-dead-count selected*)
          (token-sampling-selection-candidate-count selected*)))]))

(: text-fast-supported? (-> (Listof observer-state) Boolean))
(define (text-fast-supported? states)
  (andmap
   (lambda ([st : observer-state])
     (define w (observer-state-observer st))
     (or (compiled-rank-observer? w)
         (compiled-ban-observer? w)
         (rx-compiled-rank-observer? w)
         (rx-compiled-ban-observer? w)))
   states))

(: make-text-token-delta (-> (Listof observer-state) Real (-> TokenId Real)))
(define (make-text-token-delta states lambda-weight)
  (define default-delta : Real 0.0)
  (define overrides : (HashTable TokenId Real) (make-hash))
  (for ([st (in-list states)])
    (unless (or (observer-state-matched? st)
                (observer-state-dead? st))
      (define w (observer-state-observer st))
      (cond
        [(compiled-rank-observer? w)
         (define observer-default (rank-observer-default-delta st lambda-weight))
         (set! default-delta (+ default-delta observer-default))
         (fill-rank-token-deltas! st w overrides lambda-weight observer-default)]
        [(compiled-ban-observer? w)
         (fill-ban-token-deltas! st w overrides)]
        [(rx-compiled-rank-observer? w)
         (for ([id (in-list (rx-compiled-rank-observer-token-ids w))])
           (define amount (rx-compiled-rank-observer-score w))
           (add-token-delta! overrides id
                             (+ amount (* lambda-weight (max 0.0 amount)))))]
        [(rx-compiled-ban-observer? w)
         (cond
           [(pair? (rx-compiled-ban-observer-token-ids w))
           (for ([id (in-list (rx-compiled-ban-observer-token-ids w))])
              (add-token-delta! overrides id neg-inf))]
           [else
            (define machine (rx-compiled-ban-observer-machine w))
            (define state (regex-state-after machine (observer-state-ids st)))
            (when state
              (for ([id (in-list (regex-accepted-ids machine state))])
                (add-token-delta! overrides id neg-inf)))])]
        [else (void)])))
  (lambda ([id : TokenId])
    (define sparse-delta (hash-ref overrides id (lambda () 0.0)))
    (if (log-score-dead? sparse-delta)
        neg-inf
        (+ default-delta sparse-delta))))

(: rank-observer-default-delta (-> observer-state Real Real))
(define (rank-observer-default-delta st lambda-weight)
  (* lambda-weight (- (observer-state-potential st))))

(: fill-rank-token-deltas!
   (-> observer-state compiled-rank-observer (HashTable TokenId Real) Real Real Void))
(define (fill-rank-token-deltas! st observer deltas lambda-weight observer-default)
  (define needle (compiled-rank-observer-ids observer))
  (unless (null? needle)
    (define candidate-ids
      (remove-duplicates
       (for/list : TokenIds ([n : Natural (in-range 1 (add1 (length needle)))]
                             #:when (suffix-matches-prefix?
                                      (observer-state-ids st)
                                      needle
                                      (assert (sub1 n) exact-nonnegative-integer?)))
         (list-ref needle (assert (sub1 n) exact-nonnegative-integer?)))))
    (for ([id (in-list candidate-ids)])
      (define next-ids (append (observer-state-ids st) (list id)))
      (define matched? (contains-subsequence? next-ids needle))
      (define next-score (if matched? (compiled-rank-observer-score observer) 0.0))
      (define next-potential
        (if matched?
            0.0
            (rank-potential next-ids needle (compiled-rank-observer-score observer))))
      (define local-delta
        (+ (- next-score (observer-state-score st))
           (* lambda-weight (- next-potential (observer-state-potential st)))))
      (add-token-delta! deltas id (- local-delta observer-default)))))

(: fill-ban-token-deltas!
   (-> observer-state compiled-ban-observer (HashTable TokenId Real) Void))
(define (fill-ban-token-deltas! st observer deltas)
  (define needle (compiled-ban-observer-ids observer))
  (unless (null? needle)
    (when (suffix-matches-prefix? (observer-state-ids st)
                                  needle
                                  (assert (sub1 (length needle)) exact-nonnegative-integer?))
      (add-token-delta! deltas (last needle) neg-inf))))

(: add-token-delta! (-> (HashTable TokenId Real) TokenId Real Void))
(define (add-token-delta! deltas id delta)
  (define current (hash-ref deltas id (lambda () 0.0)))
  (hash-set! deltas
             id
             (if (or (log-score-dead? current)
                     (log-score-dead? delta))
                 neg-inf
                 (+ current delta))))

(: guidance-segment-candidates (-> Guidance GuidanceState Natural (Listof segment-candidate)))
(define (guidance-segment-candidates f st vocab-size)
  (cond
    [(guidance-dead? st) '()]
    [else
     (dedupe-segment-candidates
      (cond
        [(%lit-program? f)
         (define s (assert-lit-state st))
         (define remaining (drop (%lit-program-ids f) (lit-state-pos s)))
         (if (null? remaining) '() (make-live-segment f st remaining))]
        [(%rx-program? f)
         (for*/list : (Listof segment-candidate)
                    ([id (in-list (regex-allowed-ids (%rx-program-machine f)
                                                     (rx-state-state (assert-rx-state st))))]
                     [candidate (in-list (make-live-segment f st (list id)))])
           candidate)]
        [(%pure-program? f) '()]
        [(%choice-program? f)
         (define s (assert-choice-state st))
         (append-map
          (lambda ([child : Guidance] [child-state : GuidanceState])
            (if (guidance-dead? child-state)
                '()
                (for*/list : (Listof segment-candidate)
                           ([candidate (in-list (guidance-segment-candidates child child-state vocab-size))]
                            [whole (in-list (make-live-segment f st (segment-candidate-ids candidate)))])
                  whole)))
          (%choice-program-options f)
          (choice-state-children s))]
        [(%seq-program? f)
         (define s (assert-seq-state st))
         (if (>= (seq-state-index s) (length (%seq-program-children f)))
             '()
             (let ([child (list-ref (%seq-program-children f) (seq-state-index s))])
               (for*/list : (Listof segment-candidate)
                          ([candidate (in-list (guidance-segment-candidates child (seq-state-child s) vocab-size))]
                           [whole (in-list (make-live-segment f st (segment-candidate-ids candidate)))])
                 whole)))]
        [(%repeat-program? f)
         (define s (assert-repeat-state st))
         (if (>= (repeat-state-count s) (%repeat-program-max-count f))
             '()
             (for*/list : (Listof segment-candidate)
                        ([candidate (in-list (guidance-segment-candidates (%repeat-program-item f)
                                                                          (repeat-state-child s)
                                                                          vocab-size))]
                         [whole (in-list (make-live-segment f st (segment-candidate-ids candidate)))])
               whole))]
        [(%bind-program? f)
         (define s (assert-bind-state st))
         (define active
           (if (eq? (bind-state-phase s) 'first)
               (%bind-program-first f)
               (assert (bind-state-cont-guidance s) values)))
         (for*/list : (Listof segment-candidate)
                    ([candidate (in-list (guidance-segment-candidates active (bind-state-child s) vocab-size))]
                     [whole (in-list (make-live-segment f st (segment-candidate-ids candidate)))])
           whole)]
        [(%score-program? f)
         (define s (assert-score-state st))
         (for*/list : (Listof segment-candidate)
                    ([candidate (in-list (guidance-segment-candidates (%score-program-child f)
                                                                      (score-state-child s)
                                                                      vocab-size))]
                     [whole (in-list (make-live-segment f st (segment-candidate-ids candidate)))])
           whole)]
        [(%text-guidance? f)
         (for*/list : (Listof segment-candidate)
                    ([id : Natural (in-range vocab-size)]
                     [candidate (in-list (make-live-segment f st (list id)))])
               candidate)]))]))

;; Exact one-token frontier used by generation strategies. Segment candidates
;; remain an internal optimization for constructing the frontier.
(: guidance-allowed-token-ids (-> Guidance GuidanceState Natural TokenIds))
(define (guidance-allowed-token-ids f st vocab-size)
  (sort
   (remove-duplicates
    (for/list : TokenIds
              ([candidate (in-list (guidance-segment-candidates f st vocab-size))]
               #:when (pair? (segment-candidate-ids candidate)))
      (car (segment-candidate-ids candidate))))
   <))

(: make-live-segment (-> Guidance GuidanceState TokenIds (Listof segment-candidate)))
(define (make-live-segment f st ids)
  (cond
    [(null? ids) '()]
    [else
     (define next (guidance-step-segment f st ids))
     (if (guidance-dead? next)
         '()
         (list
          (segment-candidate
           ids
           next
           (- (guidance-score next) (guidance-score st))
           (- (guidance-potential next) (guidance-potential st)))))]))

(: guidance-step-segment (-> Guidance GuidanceState TokenIds GuidanceState))
(define (guidance-step-segment f st ids)
  (for/fold ([next : GuidanceState st])
            ([id (in-list ids)])
    (guidance-step f next id)))

(: dedupe-segment-candidates (-> (Listof segment-candidate) (Listof segment-candidate)))
(define (dedupe-segment-candidates candidates)
  (define seen : (HashTable TokenIds Boolean) (make-hash))
  (reverse
   (for/fold ([out : (Listof segment-candidate) '()])
             ([candidate (in-list candidates)])
     (define ids (segment-candidate-ids candidate))
     (if (hash-has-key? seen ids)
         out
         (begin
           (hash-set! seen ids #t)
           (cons candidate out))))))

(: guidance-accepting? (-> GuidanceState Boolean))
(define (guidance-accepting? st)
  (cond
    [(lit-state? st) (= (lit-state-pos st) (lit-state-len st))]
    [(rx-state? st) (rx-state-accepting? st)]
    [(pure-state? st) #t]
    [(choice-state? st) (ormap guidance-accepting? (choice-state-children st))]
    [(seq-state? st) (>= (seq-state-index st) (seq-state-len st))]
    [(repeat-state? st) (>= (repeat-state-count st) (repeat-state-min-count st))]
    [(bind-state? st) (and (eq? (bind-state-phase st) 'cont)
                           (guidance-accepting? (bind-state-child st)))]
    [(score-state? st) (guidance-accepting? (score-state-child st))]
    [(text-state? st) (>= (length (text-state-ids st)) (text-state-max-tokens st))]
    [(dead-state? st) #f]))

;; The caller's generation budget is also a valid boundary for a root text
;; program. Composite programs still use their explicit text limit.
(: guidance-budget-accepting? (-> GuidanceState Boolean))
(define (guidance-budget-accepting? st)
  (or (text-state? st) (guidance-accepting? st)))

(: guidance-terminal? (-> Guidance GuidanceState Boolean))
(define (guidance-terminal? f st)
  (cond
    [(guidance-dead? st) #t]
    [(%lit-program? f) (guidance-accepting? st)]
    [(%rx-program? f)
     (regex-terminal? (%rx-program-machine f)
                      (rx-state-state (assert-rx-state st)))]
    [(%pure-program? f) #t]
    [(%choice-program? f)
     (define s (assert-choice-state st))
     (for/and : Boolean ([child (in-list (%choice-program-options f))]
                         [child-state (in-list (choice-state-children s))]
                         #:unless (guidance-dead? child-state))
       (guidance-terminal? child child-state))]
    [(%seq-program? f) (and (seq-state? st) (>= (seq-state-index st) (length (%seq-program-children f))))]
    [(%repeat-program? f) (and (repeat-state? st) (>= (repeat-state-count st) (%repeat-program-max-count f)))]
    [(%bind-program? f)
     (define s (assert-bind-state st))
     (and (eq? (bind-state-phase s) 'cont)
          (guidance-terminal? (assert (bind-state-cont-guidance s) values)
                            (bind-state-child s)))]
    [(%score-program? f) (guidance-terminal? (%score-program-child f)
                                         (score-state-child (assert-score-state st)))]
    [(%text-guidance? f) (and (text-state? st) (>= (length (text-state-ids st)) (%text-guidance-max-tokens f)))]))

(: guidance-dead? (-> GuidanceState Boolean))
(define (guidance-dead? st)
  (cond
    [(dead-state? st) #t]
    [(choice-state? st) (andmap guidance-dead? (choice-state-children st))]
    [(score-state? st) (guidance-dead? (score-state-child st))]
    [(text-state? st) (ormap observer-state-dead? (text-state-observer-states st))]
    [else #f]))

(: guidance-score (-> GuidanceState Real))
(define (guidance-score st)
  (cond
    [(dead-state? st) neg-inf]
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:unless (guidance-dead? s))
       (max best (guidance-score s)))]
    [(seq-state? st) (seq-state-score st)]
    [(repeat-state? st) (repeat-state-score st)]
    [(bind-state? st) (log-score-add (bind-state-score st)
                                     (guidance-score (bind-state-child st)))]
    [(score-state? st)
     (define child (score-state-child st))
     (if (guidance-accepting? child)
         (log-score-add (guidance-score child) (score-state-score st))
         (guidance-score child))]
    [(text-state? st) (observer-states-score (text-state-observer-states st))]
    [else 0.0]))

(: guidance-accepted-score (-> GuidanceState Real))
(define (guidance-accepted-score st)
  (cond
    [(not (guidance-accepting? st)) neg-inf]
    [(dead-state? st) neg-inf]
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:when (guidance-accepting? s))
       (max best (guidance-accepted-score s)))]
    [(seq-state? st) (seq-state-score st)]
    [(repeat-state? st) (repeat-state-score st)]
    [(bind-state? st) (log-score-add (bind-state-score st)
                                     (guidance-accepted-score (bind-state-child st)))]
    [(score-state? st)
     (log-score-add (guidance-accepted-score (score-state-child st))
                    (score-state-score st))]
    [(text-state? st) (observer-states-score (text-state-observer-states st))]
    [else 0.0]))

(: guidance-potential (-> GuidanceState Real))
(define (guidance-potential st)
  (cond
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:unless (guidance-dead? s))
       (max best (guidance-potential s)))]
    [(text-state? st) (observer-states-potential (text-state-observer-states st))]
    [(score-state? st) (guidance-potential (score-state-child st))]
    [else 0.0]))

(: guidance-value (-> GuidanceState Any))
(define (guidance-value st)
  (cond
    [(pure-state? st) (pure-state-value st)]
    [(choice-state? st)
     (define accepted (filter guidance-accepting? (choice-state-children st)))
     (and (pair? accepted)
          (guidance-value
           (argmax guidance-accepted-score accepted)))]
    [(seq-state? st) (seq-state-value st)]
    [(repeat-state? st) (reverse (repeat-state-values st))]
    [(bind-state? st) (guidance-value (bind-state-child st))]
    [(text-state? st) (text-state-ids st)]
    [else (void)]))

(: guidance-token-ids (-> GuidanceState TokenIds))
(define (guidance-token-ids st)
  (cond
    [(seq-state? st) (seq-state-ids st)]
    [(repeat-state? st) (repeat-state-ids st)]
    [(bind-state? st) (bind-state-ids st)]
    [(text-state? st) (text-state-ids st)]
    [(dead-state? st) (dead-state-ids st)]
    [else '()]))

(: guidance-trace (-> GuidanceState (Listof Any)))
(define (guidance-trace st)
  (cond
    [(dead-state? st) (dead-state-trace st)]
    [(text-state? st) (append-map observer-state-trace (text-state-observer-states st))]
    [else '()]))

(: observer-initial (-> CompiledTextObserver observer-state))
(define (observer-initial w)
  (observer-state w '() #f #f 0.0
                  (if (rx-compiled-rank-observer? w)
                      (- (max 0.0 (rx-compiled-rank-observer-score w)))
                      0.0)
                  '()))

(: observer-step (-> observer-state TokenId observer-state))
(define (observer-step st id)
  (if (or (observer-state-matched? st) (observer-state-dead? st))
      st
      (observer-evaluate st (append (observer-state-ids st) (list id)))))

(: observer-evaluate (-> observer-state TokenIds observer-state))
(define (observer-evaluate st ids)
  (define w (observer-state-observer st))
  (cond
    [(compiled-rank-observer? w)
     (define matched? (contains-subsequence? ids (compiled-rank-observer-ids w)))
     (define potential (if matched? 0.0 (rank-potential ids (compiled-rank-observer-ids w) (compiled-rank-observer-score w))))
     (observer-state w ids matched? #f
                  (if matched? (compiled-rank-observer-score w) 0.0)
                  potential
                  (if matched? (list (list 'rank (compiled-rank-observer-score w) (compiled-rank-observer-ids w))) '()))]
    [(compiled-ban-observer? w)
     (define matched? (contains-subsequence? ids (compiled-ban-observer-ids w)))
     (observer-state w ids matched? matched?
                  (if matched? neg-inf 0.0)
                  0.0
                  (if matched? (list (list 'ban neg-inf (compiled-ban-observer-ids w))) '()))]
    [(rx-compiled-rank-observer? w)
     (define matched? (regex-ids-match? (rx-compiled-rank-observer-machine w) ids))
     (observer-state w ids matched? #f
                  (if matched? (rx-compiled-rank-observer-score w) 0.0)
                  (if matched?
                      0.0
                      (- (max 0.0 (rx-compiled-rank-observer-score w))))
                  (if matched? (list (list 'rank-rx (rx-compiled-rank-observer-score w))) '()))]
    [(rx-compiled-ban-observer? w)
     (define matched? (regex-ids-match? (rx-compiled-ban-observer-machine w) ids))
     (observer-state w ids matched? matched?
                  (if matched? neg-inf 0.0)
                  0.0
                  (if matched? (list (list 'ban-rx neg-inf)) '()))]
    [(compiled-weighted-observer? w)
     (define matched-rules
       (filter (lambda ([rule : weighted-rule])
                 (contains-subsequence? ids (weighted-rule-ids rule)))
               (compiled-weighted-observer-rules w)))
     (observer-state w ids (pair? matched-rules) #f
                  (for/fold ([score : Real 0.0])
                            ([rule (in-list matched-rules)])
                    (log-score-add score (weighted-rule-score rule)))
                  0.0
                  (for/list : (Listof Any) ([rule (in-list matched-rules)])
                    (list 'weight (weighted-rule-score rule) (weighted-rule-source rule))))]))

(: regex-ids-match? (-> RegexMachine TokenIds Boolean))
(define (regex-ids-match? machine ids)
  (let loop ([state : (Option RegexState) (regex-initial machine)]
             [remaining : TokenIds ids])
    (cond
      [(not state) #f]
      [(null? remaining) (regex-accepting? machine state)]
      [else (loop (regex-step machine state (car remaining))
                  (cdr remaining))])))

(: regex-state-after (-> RegexMachine TokenIds (Option RegexState)))
(define (regex-state-after machine ids)
  (let loop ([state : (Option RegexState) (regex-initial machine)]
             [remaining : TokenIds ids])
    (cond
      [(not state) #f]
      [(null? remaining) state]
      [else (loop (regex-step machine state (car remaining))
                  (cdr remaining))])))

(: observer-states-score (-> (Listof observer-state) Real))
(define (observer-states-score states)
  (for/fold ([score : Real 0.0])
            ([s (in-list states)])
    (if (observer-state-dead? s)
        neg-inf
        (log-score-add score (observer-state-score s)))))

(: observer-states-potential (-> (Listof observer-state) Real))
(define (observer-states-potential states)
  (for/sum : Real ([s (in-list states)])
    (observer-state-potential s)))

(: contains-subsequence? (-> TokenIds TokenIds Boolean))
(define (contains-subsequence? xs needle)
  (cond
    [(null? needle) #t]
    [(< (length xs) (length needle)) #f]
    [else
     (for/or : Boolean ([start (in-range (add1 (- (length xs) (length needle))))])
       (equal? needle (take (drop xs start) (length needle))))]))

(: suffix-matches-prefix? (-> TokenIds TokenIds Natural Boolean))
(define (suffix-matches-prefix? ids needle count)
  (cond
    [(zero? count) #t]
    [(> count (length ids)) #f]
    [(> count (length needle)) #f]
    [else (equal? (take-right ids count) (take needle count))]))

(: rank-potential (-> TokenIds TokenIds Real Real))
(define (rank-potential xs needle score)
  (if (or (<= score 0.0) (null? needle))
      0.0
      (let ([progress
             (for/fold ([best : Natural 0])
                       ([n : Natural (in-range 1 (add1 (length needle)))])
               (if (and (<= n (length xs))
                        (equal? (take-right xs n) (take needle n)))
                   n
                   best))])
        (* score (/ progress (length needle))))))

(: assert-lit-state (-> GuidanceState lit-state))
(define (assert-lit-state v) (assert v lit-state?))
(: assert-rx-state (-> GuidanceState rx-state))
(define (assert-rx-state v) (assert v rx-state?))
(: assert-choice-state (-> GuidanceState (choice-state GuidanceState)))
(define (assert-choice-state v) (assert v choice-state?))
(: assert-seq-state (-> GuidanceState (seq-state GuidanceState)))
(define (assert-seq-state v) (assert v seq-state?))
(: assert-repeat-state (-> GuidanceState (repeat-state GuidanceState)))
(define (assert-repeat-state v) (assert v repeat-state?))
(: assert-bind-state (-> GuidanceState (bind-state GuidanceState)))
(define (assert-bind-state v) (assert v bind-state?))
(: assert-score-state (-> GuidanceState (score-state GuidanceState)))
(define (assert-score-state v) (assert v score-state?))
(: assert-text-state (-> GuidanceState text-state))
(define (assert-text-state v) (assert v text-state?))
