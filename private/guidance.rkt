#lang typed/racket/base

(require racket/list
         racket/string
         (only-in "regex.rkt"
                  ErePattern RegexMachine RegexProgram RegexState RegexVocabulary
                  ere-full-program ere-search-program ere-pattern-source
                  instantiate-regex-machine literal-search-program
                  regex-accepting? regex-accepted-ids regex-allowed-ids
                  regex-initial regex-step regex-terminal?))

(provide Program ControlRule Guidance GuidanceState
         make-lit-program make-rx-program make-ere-program make-pure-program
         make-choice-program make-seq-program make-repeat-program make-bind-program
         make-text-program make-control-program
         make-prefer-rule make-avoid-rule make-ban-rule
         program-pwsg-compatible? program-pwsg-errors program-layout-errors program-has-weak-rules?
         program-schema-descriptors program-canonical-form
         compile-guidance guidance-initial guidance-step guidance-allowed-token-ids
         guidance-accepting? guidance-terminal? guidance-dead? guidance-value
         (struct-out weak-match) guidance-weak-matches guidance-trace)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
(define-type TokenizeProc (-> String TokenIds))

;; Public descriptions are explicit AST nodes. Dynamic bind remains available
;; for hard-only generation, but is deliberately outside the PWSG profile.
(struct lit-program ([source : String]) #:transparent)
(struct rx-program ([regex : RegexProgram]) #:transparent)
(struct ere-program ([pattern : ErePattern]) #:transparent)
(struct pure-program ([value : Any]) #:transparent)
(struct (A) choice-program ([options : (Listof A)]) #:transparent)
(struct (A) seq-program ([children : (Listof A)]) #:transparent)
(struct (A) repeat-program ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct (A) bind-program ([first : A] [continue : (-> Any A)]) #:transparent)
(struct text-program ([max-tokens : Natural]) #:transparent)
(struct (A R) control-program ([child : A] [rules : (Listof R)]) #:transparent)

(define-type Program
  (Rec P (U lit-program rx-program ere-program pure-program
            (choice-program P) (seq-program P) (repeat-program P)
            (bind-program P) text-program (control-program P ControlRule))))

(struct prefer-rule ([pattern : (U lit-program ere-program)]) #:transparent)
(struct avoid-rule ([pattern : (U lit-program ere-program)]) #:transparent)
(struct ban-rule ([pattern : (U lit-program ere-program)]) #:transparent)
(define-type ControlRule (U prefer-rule avoid-rule ban-rule))

(: make-lit-program (-> String Program))
(define (make-lit-program source) (lit-program source))
(: make-rx-program (-> RegexProgram Program))
(define (make-rx-program regex) (rx-program regex))
(: make-ere-program (-> ErePattern Program))
(define (make-ere-program pattern) (ere-program pattern))
(: make-pure-program (-> Any Program))
(define (make-pure-program value) (pure-program value))
(: make-choice-program (-> (Listof Program) Program))
(define (make-choice-program xs) (choice-program xs))
(: make-seq-program (-> (Listof Program) Program))
(define (make-seq-program xs) (seq-program xs))
(: make-repeat-program (-> Natural Natural Program Program))
(define (make-repeat-program min-count max-count item)
  (when (> min-count max-count)
    (raise-arguments-error 'repeat "minimum exceeds maximum"
                           "minimum" min-count "maximum" max-count))
  (repeat-program min-count max-count item))
(: make-bind-program (-> Program (-> Any Program) Program))
(define (make-bind-program first continue) (bind-program first continue))
(: make-text-program (-> Natural Program))
(define (make-text-program max-tokens) (text-program max-tokens))
(: make-control-program (-> Program (Listof ControlRule) Program))
(define (make-control-program child rules) (control-program child rules))

(: rule-pattern (-> Symbol Program (U lit-program ere-program)))
(define (rule-pattern who pattern)
  (cond [(lit-program? pattern) pattern]
        [(ere-program? pattern) pattern]
        [else (raise-argument-error who "a value produced by lit or ere" pattern)]))
(: make-prefer-rule (-> Program ControlRule))
(define (make-prefer-rule p) (prefer-rule (rule-pattern 'prefer p)))
(: make-avoid-rule (-> Program ControlRule))
(define (make-avoid-rule p) (avoid-rule (rule-pattern 'avoid p)))
(: make-ban-rule (-> Program ControlRule))
(define (make-ban-rule p) (ban-rule (rule-pattern 'ban p)))

;; Compiled token-native runtime.
(struct %lit ([ids : TokenIds]) #:transparent)
(struct %regex ([machine : RegexMachine]) #:transparent)
(struct %pure ([value : Any]) #:transparent)
(struct (A) %choice ([options : (Listof A)]) #:transparent)
(struct (A) %seq ([children : (Listof A)]) #:transparent)
(struct (A) %repeat ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct (A) %bind ([first : A] [continue : (-> Any A)]) #:transparent)
(struct %text ([max-tokens : Natural]) #:transparent)
(struct compiled-rule
  ([path : String] [polarity : Symbol] [kind : Symbol]
   [machine : RegexMachine] [end-anchor? : Boolean])
  #:transparent)
(struct (A) %control ([child : A] [rules : (Listof compiled-rule)]) #:transparent)

(define-type Guidance
  (Rec G (U %lit %regex %pure (%choice G) (%seq G) (%repeat G)
            (%bind G) %text (%control G))))

;; One match record per active control occurrence. Aggregation across repeated
;; occurrences and missing branches happens in the weak-observation layer.
(struct weak-match
  ([path : String] [polarity : Symbol] [matched? : Boolean]
   [start-token : Natural] [end-token : Natural] [token-ids : TokenIds])
  #:transparent)

(struct lit-state ([pos : Natural] [len : Natural]) #:transparent)
(struct regex-state ([state : RegexState] [accepting? : Boolean]) #:transparent)
(struct pure-state ([value : Any]) #:transparent)
(struct (A) choice-state ([children : (Listof A)]) #:transparent)
(struct (A) seq-state
  ([index : Natural] [children-count : Natural] [child : A]
   [values : (Listof Any)] [captures : (Listof weak-match)] [start : Natural]
   [consumed : Natural])
  #:transparent)
(struct (A) repeat-state
  ([count : Natural] [min-count : Natural] [max-count : Natural] [child : A]
   [in-item? : Boolean] [values : (Listof Any)] [captures : (Listof weak-match)]
   [start : Natural] [consumed : Natural])
  #:transparent)
(struct (A) bind-state
  ([phase : Symbol] [child : A] [cont : (Option Guidance)]
   [captures : (Listof weak-match)] [start : Natural] [consumed : Natural])
  #:transparent)
(struct text-state ([count : Natural] [max-tokens : Natural]) #:transparent)
(struct ban-runtime
  ([rule : compiled-rule] [state : RegexState] [latched? : Boolean])
  #:transparent)
(struct (A) control-state
  ([child : A] [rules : (Listof compiled-rule)] [bans : (Listof ban-runtime)]
   [start : Natural] [ids : TokenIds] [hard-dead? : Boolean])
  #:transparent)
(struct dead-state ([trace : (Listof Any)]) #:transparent)

(define-type GuidanceState
  (Rec S (U lit-state regex-state pure-state (choice-state S) (seq-state S)
            (repeat-state S) (bind-state S) text-state (control-state S) dead-state)))

(: path-child (-> String Symbol Natural String))
(define (path-child base kind index) (format "~a/~a[~a]" base kind index))

(: compile-rule (-> ControlRule String Natural RegexVocabulary compiled-rule))
(define (compile-rule rule control-path index vocabulary)
  (define pattern
    (cond [(prefer-rule? rule) (prefer-rule-pattern rule)]
          [(avoid-rule? rule) (avoid-rule-pattern rule)]
          [else (ban-rule-pattern (assert rule ban-rule?))]))
  (define polarity (cond [(prefer-rule? rule) 'prefer]
                         [(avoid-rule? rule) 'avoid]
                         [else 'ban]))
  (define kind (if (lit-program? pattern) 'literal 'ere))
  (define regex
    (if (lit-program? pattern)
        (literal-search-program (lit-program-source pattern))
        (ere-search-program (ere-program-pattern (assert pattern ere-program?)))))
  (compiled-rule (format "~a/control/rule[~a]" control-path index)
                 polarity kind (instantiate-regex-machine regex vocabulary)
                 (and (ere-program? pattern)
                      (let ([source (ere-pattern-source (ere-program-pattern pattern))])
                        (regexp-match? #px"(^|[^\\\\])\\$" source)))))

(: compile-guidance (-> Program TokenizeProc RegexVocabulary Guidance))
(define (compile-guidance program tokenize-text vocabulary)
  (let compile : Guidance ([p : Program program] [path : String "root"])
    (cond
      [(lit-program? p) (%lit (tokenize-text (lit-program-source p)))]
      [(rx-program? p) (%regex (instantiate-regex-machine (rx-program-regex p) vocabulary))]
      [(ere-program? p) (%regex (instantiate-regex-machine
                                 (ere-full-program (ere-program-pattern p)) vocabulary))]
      [(pure-program? p) (%pure (pure-program-value p))]
      [(choice-program? p)
       (%choice (for/list : (Listof Guidance) ([child (in-list (choice-program-options p))]
                                               [i : Natural (in-naturals)])
                  (compile child (path-child path 'choice i))))]
      [(seq-program? p)
       (%seq (for/list : (Listof Guidance) ([child (in-list (seq-program-children p))]
                                            [i : Natural (in-naturals)])
               (compile child (path-child path 'seq i))))]
      [(repeat-program? p)
       (%repeat (repeat-program-min-count p) (repeat-program-max-count p)
                (compile (repeat-program-item p) (format "~a/repeat" path)))]
      [(bind-program? p)
       (%bind (compile (bind-program-first p) (format "~a/bind/first" path))
              (lambda ([value : Any])
                (compile ((bind-program-continue p) value) (format "~a/bind/cont" path))))]
      [(text-program? p) (%text (text-program-max-tokens p))]
      [else
       (define cp (assert p control-program?))
       (%control
        (compile (control-program-child cp) (format "~a/control/child" path))
        (for/list : (Listof compiled-rule) ([rule (in-list (control-program-rules cp))]
                                            [i : Natural (in-naturals)])
          (compile-rule rule path i vocabulary)))])))

(: guidance-initial (->* (Guidance) (Natural) GuidanceState))
(define (guidance-initial f [start 0])
  (define raw : GuidanceState
    (cond
      [(%lit? f) (lit-state 0 (length (%lit-ids f)))]
      [(%regex? f)
       (define st (regex-initial (%regex-machine f)))
       (regex-state st (regex-accepting? (%regex-machine f) st))]
      [(%pure? f) (pure-state (%pure-value f))]
      [(%choice? f) (choice-state (map (lambda ([g : Guidance]) (guidance-initial g start))
                                        (%choice-options f)))]
      [(%seq? f)
       (define children (%seq-children f))
       (if (null? children)
           (pure-state (void))
           (seq-state 0 (length children) (guidance-initial (car children) start)
                      '() '() start 0))]
      [(%repeat? f)
       (define child (guidance-initial (%repeat-item f) start))
       (when (guidance-accepting? child)
         (error 'repeat "nullable repeated programs are unsupported"))
       (repeat-state 0 (%repeat-min-count f) (%repeat-max-count f) child
                     #f '() '() start 0)]
      [(%bind? f)
       (bind-state 'first (guidance-initial (%bind-first f) start) #f '() start 0)]
      [(%text? f) (text-state 0 (%text-max-tokens f))]
      [else
       (define control (assert f %control?))
       (control-state
        (guidance-initial (%control-child control) start)
        (%control-rules control)
        (for/list : (Listof ban-runtime) ([rule (in-list (%control-rules control))]
                                          #:when (eq? (compiled-rule-polarity rule) 'ban))
          (ban-runtime rule (regex-initial (compiled-rule-machine rule)) #f))
        start '() #f)]))
  (normalize f raw))

(: guidance-step (-> Guidance GuidanceState TokenId GuidanceState))
(define (guidance-step f st id)
  (if (guidance-dead? st)
      st
      (normalize f (step-raw f st id))))

(: step-raw (-> Guidance GuidanceState TokenId GuidanceState))
(define (step-raw f st id)
  (cond
    [(%lit? f)
     (define s (assert st lit-state?))
     (if (and (< (lit-state-pos s) (lit-state-len s))
              (= id (list-ref (%lit-ids f) (lit-state-pos s))))
         (lit-state (add1 (lit-state-pos s)) (lit-state-len s))
         (dead-state (list 'lit-dead)))]
    [(%regex? f)
     (define s (assert st regex-state?))
     (define next (regex-step (%regex-machine f) (regex-state-state s) id))
     (if next
         (regex-state next (regex-accepting? (%regex-machine f) next))
         (dead-state (list 'regex-dead)))]
    [(%pure? f) (dead-state (list 'pure-terminal))]
    [(%choice? f)
     (define s (assert st choice-state?))
     (choice-state
      (for/list : (Listof GuidanceState) ([g (in-list (%choice-options f))]
                                          [child (in-list (choice-state-children s))])
        (guidance-step g child id)))]
    [(%seq? f)
     (define s (assert st seq-state?))
     (if (>= (seq-state-index s) (seq-state-children-count s))
         (dead-state (list 'seq-terminal))
         (seq-state (seq-state-index s) (seq-state-children-count s)
                    (guidance-step (list-ref (%seq-children f) (seq-state-index s))
                                   (seq-state-child s) id)
                    (seq-state-values s) (seq-state-captures s)
                    (seq-state-start s) (add1 (seq-state-consumed s))))]
    [(%repeat? f)
     (define s (assert st repeat-state?))
     (if (>= (repeat-state-count s) (repeat-state-max-count s))
         (dead-state (list 'repeat-max))
         (repeat-state (repeat-state-count s) (repeat-state-min-count s)
                       (repeat-state-max-count s)
                       (guidance-step (%repeat-item f) (repeat-state-child s) id)
                       #t (repeat-state-values s) (repeat-state-captures s)
                       (repeat-state-start s) (add1 (repeat-state-consumed s))))]
    [(%bind? f)
     (define s (assert st bind-state?))
     (define active (if (eq? (bind-state-phase s) 'first)
                        (%bind-first f) (assert (bind-state-cont s) values)))
     (bind-state (bind-state-phase s) (guidance-step active (bind-state-child s) id)
                 (bind-state-cont s) (bind-state-captures s)
                 (bind-state-start s) (add1 (bind-state-consumed s)))]
    [(%text? f)
     (define s (assert st text-state?))
     (if (< (text-state-count s) (text-state-max-tokens s))
         (text-state (add1 (text-state-count s)) (text-state-max-tokens s))
         (dead-state (list 'text-max)))]
    [else
     (define g (assert f %control?))
     (define s (assert st control-state?))
     (define next-child (guidance-step (%control-child g) (control-state-child s) id))
     (define next-bans
       (for/list : (Listof ban-runtime) ([ban (in-list (control-state-bans s))])
         (define next (regex-step (compiled-rule-machine (ban-runtime-rule ban))
                                  (ban-runtime-state ban) id))
         (if next
             (ban-runtime
              (ban-runtime-rule ban) next
              (or (ban-runtime-latched? ban)
                  (and (not (compiled-rule-end-anchor? (ban-runtime-rule ban)))
                       (regex-accepting? (compiled-rule-machine (ban-runtime-rule ban)) next))))
             (ban-runtime (ban-runtime-rule ban) (ban-runtime-state ban) #f))))
     (control-state next-child (control-state-rules s) next-bans
                    (control-state-start s) (append (control-state-ids s) (list id))
                    (or (control-state-hard-dead? s)
                        (ormap ban-runtime-latched? next-bans)))]))

(: normalize (-> Guidance GuidanceState GuidanceState))
(define (normalize f st)
  (cond
    [(%seq? f) (normalize-seq f (assert st seq-state?))]
    [(%repeat? f) (normalize-repeat f (assert st repeat-state?))]
    [(%bind? f) (normalize-bind f (assert st bind-state?))]
    [else st]))

(: normalize-seq (-> (%seq Guidance) (seq-state GuidanceState) GuidanceState))
(define (normalize-seq f st0)
  (let loop : GuidanceState ([st : (seq-state GuidanceState) st0])
    (define children (%seq-children f))
    (define child (seq-state-child st))
    (cond
      [(guidance-dead? child) (dead-state (guidance-trace child))]
      [(and (guidance-accepting? child)
            (< (add1 (seq-state-index st)) (length children)))
       (define next-index (add1 (seq-state-index st)))
       (loop (seq-state next-index (seq-state-children-count st)
                        (guidance-initial (list-ref children next-index)
                                          (+ (seq-state-start st) (seq-state-consumed st)))
                        (append (seq-state-values st) (list (guidance-value child)))
                        (append (seq-state-captures st) (guidance-weak-matches child))
                        (seq-state-start st) (seq-state-consumed st)))]
      [else st])))

(: normalize-repeat (-> (%repeat Guidance) (repeat-state GuidanceState) GuidanceState))
(define (normalize-repeat f st)
  (define child (repeat-state-child st))
  (cond
    [(guidance-dead? child) (dead-state (guidance-trace child))]
    [(and (repeat-state-in-item? st) (guidance-accepting? child))
     (define count (add1 (repeat-state-count st)))
     (define values (append (repeat-state-values st) (list (guidance-value child))))
     (define captures (append (repeat-state-captures st) (guidance-weak-matches child)))
     (if (>= count (repeat-state-max-count st))
         (repeat-state count (repeat-state-min-count st) (repeat-state-max-count st)
                       child #f values captures (repeat-state-start st)
                       (repeat-state-consumed st))
         (repeat-state count (repeat-state-min-count st) (repeat-state-max-count st)
                       (guidance-initial (%repeat-item f)
                                         (+ (repeat-state-start st) (repeat-state-consumed st)))
                       #f values captures (repeat-state-start st)
                       (repeat-state-consumed st)))]
    [else st]))

(: normalize-bind (-> (%bind Guidance) (bind-state GuidanceState) GuidanceState))
(define (normalize-bind f st)
  (define child (bind-state-child st))
  (cond
    [(guidance-dead? child) (dead-state (guidance-trace child))]
    [(and (eq? (bind-state-phase st) 'first) (guidance-accepting? child))
     (define cont ((%bind-continue f) (guidance-value child)))
     (bind-state 'cont
                 (guidance-initial cont (+ (bind-state-start st) (bind-state-consumed st)))
                 cont (append (bind-state-captures st) (guidance-weak-matches child))
                 (bind-state-start st) (bind-state-consumed st))]
    [else st]))

(: boundary-ban? (-> (control-state GuidanceState) Boolean))
(define (boundary-ban? st)
  (ormap
   (lambda ([ban : ban-runtime])
     (or (ban-runtime-latched? ban)
         (and (compiled-rule-end-anchor? (ban-runtime-rule ban))
              (regex-accepting? (compiled-rule-machine (ban-runtime-rule ban))
                                (ban-runtime-state ban)))))
   (control-state-bans st)))

(: guidance-accepting? (-> GuidanceState Boolean))
(define (guidance-accepting? st)
  (cond
    [(lit-state? st) (= (lit-state-pos st) (lit-state-len st))]
    [(regex-state? st) (regex-state-accepting? st)]
    [(pure-state? st) #t]
    [(choice-state? st) (ormap guidance-accepting? (choice-state-children st))]
    [(seq-state? st)
     (and (= (seq-state-index st) (sub1 (seq-state-children-count st)))
          (guidance-accepting? (seq-state-child st)))]
    [(repeat-state? st)
     (and (not (repeat-state-in-item? st))
          (>= (repeat-state-count st) (repeat-state-min-count st)))]
    [(bind-state? st) (and (eq? (bind-state-phase st) 'cont)
                           (guidance-accepting? (bind-state-child st)))]
    [(text-state? st) #t]
    [(control-state? st)
     (and (not (control-state-hard-dead? st))
          (guidance-accepting? (control-state-child st))
          (not (boundary-ban? st)))]
    [else #f]))

(: guidance-terminal? (-> Guidance GuidanceState Boolean))
(define (guidance-terminal? f st)
  (cond
    [(guidance-dead? st) #t]
    [(%lit? f) (guidance-accepting? st)]
    [(%regex? f) (regex-terminal? (%regex-machine f) (regex-state-state (assert st regex-state?)))]
    [(%pure? f) #t]
    [(%choice? f)
     (for/and : Boolean ([g (in-list (%choice-options f))]
                         [child (in-list (choice-state-children (assert st choice-state?)))]
                         #:unless (guidance-dead? child))
       (guidance-terminal? g child))]
    [(%seq? f)
     (define s (assert st seq-state?))
     (and (= (seq-state-index s) (sub1 (seq-state-children-count s)))
          (guidance-terminal? (list-ref (%seq-children f) (seq-state-index s))
                              (seq-state-child s)))]
    [(%repeat? f)
     (define s (assert st repeat-state?))
     (and (not (repeat-state-in-item? s))
          (= (repeat-state-count s) (repeat-state-max-count s)))]
    [(%bind? f)
     (define s (assert st bind-state?))
     (and (eq? (bind-state-phase s) 'cont)
          (guidance-terminal? (assert (bind-state-cont s) values) (bind-state-child s)))]
    [(%text? f) (= (text-state-count (assert st text-state?)) (%text-max-tokens f))]
    [else
     (define g (assert f %control?))
     (define s (assert st control-state?))
     (guidance-terminal? (%control-child g) (control-state-child s))]))

(: guidance-dead? (-> GuidanceState Boolean))
(define (guidance-dead? st)
  (cond [(dead-state? st) #t]
        [(choice-state? st) (andmap guidance-dead? (choice-state-children st))]
        [(control-state? st) (or (control-state-hard-dead? st)
                                 (guidance-dead? (control-state-child st)))]
        [else #f]))

(: first-live-or-accepting (-> (Listof GuidanceState) (Option GuidanceState)))
(define (first-live-or-accepting xs)
  (or (findf guidance-accepting? xs) (findf (lambda ([x : GuidanceState]) (not (guidance-dead? x))) xs)))

(: guidance-value (-> GuidanceState Any))
(define (guidance-value st)
  (cond
    [(pure-state? st) (pure-state-value st)]
    [(choice-state? st)
     (define child (first-live-or-accepting (choice-state-children st)))
     (and child (guidance-value child))]
    [(seq-state? st) (append (seq-state-values st) (list (guidance-value (seq-state-child st))))]
    [(repeat-state? st) (repeat-state-values st)]
    [(bind-state? st) (guidance-value (bind-state-child st))]
    [(control-state? st) (guidance-value (control-state-child st))]
    [else (void)]))

(: regex-match-ids? (-> RegexMachine TokenIds Boolean))
(define (regex-match-ids? machine ids)
  (let loop ([state : (Option RegexState) (regex-initial machine)] [rest : TokenIds ids])
    (cond [(not state) #f]
          [(null? rest) (regex-accepting? machine state)]
          [else (loop (regex-step machine state (car rest)) (cdr rest))])))

(: current-control-matches (-> (control-state GuidanceState) (Listof weak-match)))
(define (current-control-matches st)
  (append
   (guidance-weak-matches (control-state-child st))
   (for/list : (Listof weak-match) ([rule (in-list (control-state-rules st))]
                                   #:unless (eq? (compiled-rule-polarity rule) 'ban))
     (weak-match (compiled-rule-path rule) (compiled-rule-polarity rule)
                 (regex-match-ids? (compiled-rule-machine rule) (control-state-ids st))
                 (control-state-start st)
                 (+ (control-state-start st) (length (control-state-ids st)))
                 (control-state-ids st)))))

(: guidance-weak-matches (-> GuidanceState (Listof weak-match)))
(define (guidance-weak-matches st)
  (cond
    [(choice-state? st)
     (define child (first-live-or-accepting (choice-state-children st)))
     (if child (guidance-weak-matches child) '())]
    [(seq-state? st) (append (seq-state-captures st)
                             (guidance-weak-matches (seq-state-child st)))]
    [(repeat-state? st) (append (repeat-state-captures st)
                                (if (repeat-state-in-item? st)
                                    (guidance-weak-matches (repeat-state-child st)) '()))]
    [(bind-state? st) (append (bind-state-captures st)
                              (guidance-weak-matches (bind-state-child st)))]
    [(control-state? st) (current-control-matches st)]
    [else '()]))

(: guidance-trace (-> GuidanceState (Listof Any)))
(define (guidance-trace st) (if (dead-state? st) (dead-state-trace st) '()))

(: guidance-allowed-token-ids (-> Guidance GuidanceState Natural TokenIds))
(define (guidance-allowed-token-ids f st vocab-size)
  (cond
    [(guidance-dead? st) '()]
    [(%lit? f)
     (define s (assert st lit-state?))
     (if (< (lit-state-pos s) (lit-state-len s))
         (list (list-ref (%lit-ids f) (lit-state-pos s))) '())]
    [(%regex? f) (regex-allowed-ids (%regex-machine f) (regex-state-state (assert st regex-state?)))]
    [(%pure? f) '()]
    [(%choice? f)
     (define s (assert st choice-state?))
     (sort
      (remove-duplicates
       (for/fold ([ids : TokenIds '()]) ([child (in-list (%choice-options f))]
                                         [child-state (in-list (choice-state-children s))])
         (if (guidance-dead? child-state) ids
             (append ids (guidance-allowed-token-ids child child-state vocab-size)))))
      <)]
    [(%seq? f)
     (define s (assert st seq-state?))
     (if (>= (seq-state-index s) (seq-state-children-count s)) '()
         (guidance-allowed-token-ids
          (list-ref (%seq-children f) (seq-state-index s)) (seq-state-child s) vocab-size))]
    [(%repeat? f)
     (define s (assert st repeat-state?))
     (if (>= (repeat-state-count s) (repeat-state-max-count s)) '()
         (guidance-allowed-token-ids (%repeat-item f) (repeat-state-child s) vocab-size))]
    [(%bind? f)
     (define s (assert st bind-state?))
     (define active (if (eq? (bind-state-phase s) 'first)
                        (%bind-first f) (assert (bind-state-cont s) values)))
     (guidance-allowed-token-ids active (bind-state-child s) vocab-size)]
    [(%text? f)
     (define s (assert st text-state?))
     (if (< (text-state-count s) (text-state-max-tokens s))
         (range vocab-size) '())]
    [(%control? f)
     (define g (assert f %control?))
     (define s (assert st control-state?))
     (define base
       (guidance-allowed-token-ids (%control-child g) (control-state-child s) vocab-size))
     (define blocked
       (remove-duplicates
        (append-map
         (lambda ([ban : ban-runtime])
           (if (compiled-rule-end-anchor? (ban-runtime-rule ban)) '()
               (regex-accepted-ids (compiled-rule-machine (ban-runtime-rule ban))
                                   (ban-runtime-state ban))))
         (control-state-bans s))))
     (filter (lambda ([id : TokenId]) (not (and (member id blocked) #t))) base)]
    [else
     (for/list : TokenIds ([id : Natural (in-range vocab-size)]
                           #:unless (guidance-dead? (guidance-step f st id)))
       id)]))

;; Structural metadata and profile validation.
(: indexed-programs (-> (Listof Program) (Listof (Pairof Program Natural))))
(define (indexed-programs programs)
  (for/list : (Listof (Pairof Program Natural)) ([program (in-list programs)]
                                                  [i : Natural (in-naturals)])
    (cons program i)))

(: program-has-weak-rules? (-> Program Boolean))
(define (program-has-weak-rules? p)
  (cond [(control-program? p)
         (or (ormap (lambda ([r : ControlRule]) (not (ban-rule? r)))
                    (control-program-rules p))
             (program-has-weak-rules? (control-program-child p)))]
        [(choice-program? p) (ormap program-has-weak-rules? (choice-program-options p))]
        [(seq-program? p) (ormap program-has-weak-rules? (seq-program-children p))]
        [(repeat-program? p) (program-has-weak-rules? (repeat-program-item p))]
        [(bind-program? p) #t]
        [else #f]))

(: program-schema-descriptors (-> Program (Listof Any)))
(define (program-schema-descriptors p)
  (let walk : (Listof Any) ([node : Program p] [path : String "root"])
    (cond
      [(control-program? node)
       (append
        (for/list : (Listof Any) ([rule (in-list (control-program-rules node))]
                                  [i : Natural (in-naturals)]
                                  #:unless (ban-rule? rule))
          (define pattern (if (prefer-rule? rule) (prefer-rule-pattern rule)
                              (avoid-rule-pattern (assert rule avoid-rule?))))
          (list (format "~a/control/rule[~a]" path i)
                (if (prefer-rule? rule) 'prefer 'avoid)
                (if (lit-program? pattern) 'literal 'ere)))
        (walk (control-program-child node) (format "~a/control/child" path)))]
      [(choice-program? node)
       (append-map (lambda ([pair : (Pairof Program Natural)])
                     (walk (car pair) (path-child path 'choice (cdr pair))))
                   (indexed-programs (choice-program-options node)))]
      [(seq-program? node)
       (append-map (lambda ([pair : (Pairof Program Natural)])
                     (walk (car pair) (path-child path 'seq (cdr pair))))
                   (indexed-programs (seq-program-children node)))]
      [(repeat-program? node) (walk (repeat-program-item node) (format "~a/repeat" path))]
      [else '()])))

(: pattern-form (-> (U lit-program ere-program) Any))
(define (pattern-form p)
  (if (lit-program? p) (list 'lit (lit-program-source p))
      (list 'ere (ere-pattern-source (ere-program-pattern (assert p ere-program?))))))

(: program-canonical-form (-> Program Any))
(define (program-canonical-form p)
  (cond
    [(lit-program? p) (list 'lit (lit-program-source p))]
    [(rx-program? p) (list 'rx 'extended-pcre)]
    [(ere-program? p) (pattern-form p)]
    [(pure-program? p) (list 'pure (format "~s" (pure-program-value p)))]
    [(choice-program? p) (cons 'choice (map program-canonical-form (choice-program-options p)))]
    [(seq-program? p) (cons 'seq (map program-canonical-form (seq-program-children p)))]
    [(repeat-program? p) (list 'repeat (repeat-program-min-count p)
                               (repeat-program-max-count p)
                               (program-canonical-form (repeat-program-item p)))]
    [(bind-program? p) (list 'bind 'dynamic)]
    [(text-program? p) (list 'text (text-program-max-tokens p))]
    [else
     (define c (assert p control-program?))
     (list 'control (program-canonical-form (control-program-child c))
           (for/list : (Listof Any) ([r (in-list (control-program-rules c))])
             (cond [(prefer-rule? r) (list 'prefer (pattern-form (prefer-rule-pattern r)))]
                   [(avoid-rule? r) (list 'avoid (pattern-form (avoid-rule-pattern r)))]
                   [else (list 'ban (pattern-form (ban-rule-pattern (assert r ban-rule?))))])))]))

(: contains-text? (-> Program Boolean))
(define (contains-text? p)
  (cond [(text-program? p) #t]
        [(control-program? p) (contains-text? (control-program-child p))]
        [(choice-program? p) (ormap contains-text? (choice-program-options p))]
        [(seq-program? p) (ormap contains-text? (seq-program-children p))]
        [(repeat-program? p) (contains-text? (repeat-program-item p))]
        [(bind-program? p) #t]
        [else #f]))

(: tail-errors (-> Program String (Listof String)))
(define (tail-errors p path)
  (cond
    [(seq-program? p)
     (define children (seq-program-children p))
     (append
      (for/list : (Listof String) ([child (in-list children)] [i : Natural (in-naturals)]
                                   #:when (and (contains-text? child) (< i (sub1 (length children)))))
        (format "~a/seq[~a]: text must be in tail position" path i))
      (append-map (lambda ([pair : (Pairof Program Natural)])
                    (tail-errors (car pair) (path-child path 'seq (cdr pair))))
                  (indexed-programs children)))]
    [(choice-program? p)
     (append-map (lambda ([pair : (Pairof Program Natural)])
                   (tail-errors (car pair) (path-child path 'choice (cdr pair))))
                 (indexed-programs (choice-program-options p)))]
    [(repeat-program? p)
     (append (if (contains-text? (repeat-program-item p))
                 (list (format "~a/repeat: text cannot be repeated" path)) '())
             (tail-errors (repeat-program-item p) (format "~a/repeat" path)))]
    [(control-program? p) (tail-errors (control-program-child p) (format "~a/control/child" path))]
    [(bind-program? p) (list (format "~a: dynamic bind cannot be tail-validated" path))]
    [else '()]))

(: program-pwsg-errors (-> Program (Listof String)))
(define (program-pwsg-errors p)
  (define structural
    (let walk : (Listof String) ([node : Program p] [path : String "root"])
      (cond
        [(rx-program? node) (list (format "~a: rx is outside the PWSG profile" path))]
        [(pure-program? node) (list (format "~a: pure is outside the PWSG profile" path))]
        [(bind-program? node) (list (format "~a: bind is outside the PWSG profile" path))]
        [(choice-program? node)
         (append-map (lambda ([pair : (Pairof Program Natural)])
                       (walk (car pair) (path-child path 'choice (cdr pair))))
                     (indexed-programs (choice-program-options node)))]
        [(seq-program? node)
         (append-map (lambda ([pair : (Pairof Program Natural)])
                       (walk (car pair) (path-child path 'seq (cdr pair))))
                     (indexed-programs (seq-program-children node)))]
        [(repeat-program? node) (walk (repeat-program-item node) (format "~a/repeat" path))]
        [(control-program? node) (walk (control-program-child node) (format "~a/control/child" path))]
        [else '()])))
  (append structural (tail-errors p "root")))

(: program-pwsg-compatible? (-> Program Boolean))
(define (program-pwsg-compatible? p) (null? (program-pwsg-errors p)))

(: program-layout-errors (-> Program (Listof String)))
(define (program-layout-errors p) (tail-errors p "root"))
