#lang typed/racket/base

(require racket/list
         racket/string
         (only-in "domain.rkt" TokenDomain domain-all domain-none domain-only
                  domain-union domain-subtract)
         (only-in "regex.rkt"
                  ErePattern RegexMachine RegexProgram RegexState RegexVocabulary
                  ere-full-program ere-search-program ere-pattern-source
                  ere-pattern-has-end-anchor?
                  instantiate-regex-machine literal-search-program
                  regex-accepting? regex-accepted-ids regex-allowed-ids
                  regex-initial regex-step regex-terminal?))

(provide Program ControlRule Guidance GuidanceState
         make-lit-program make-rx-program make-ere-program
         make-choice-program make-seq-program make-repeat-program
         make-text-program make-control-program
         make-prefer-rule make-avoid-rule make-ban-rule
         program-pwsg-errors program-layout-errors
         program-schema-descriptors program-shape-form program-canonical-form
         compile-guidance guidance-initial guidance-step guidance-token-domain
         guidance-accepting? guidance-dead?
         (struct-out weak-match) guidance-weak-matches)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
(define-type TokenizeProc (-> String TokenIds))

;; Public descriptions are explicit immutable AST nodes.
(struct lit-program ([source : String]) #:transparent)
(struct rx-program ([regex : RegexProgram]) #:transparent)
(struct ere-program ([pattern : ErePattern]) #:transparent)
(struct (A) choice-program ([options : (Listof A)]) #:transparent)
(struct (A) seq-program ([children : (Listof A)]) #:transparent)
(struct (A) repeat-program ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct text-program ([max-tokens : Natural]) #:transparent)
(struct (A R) control-program ([child : A] [rules : (Listof R)]) #:transparent)

(define-type Program
  (Rec P (U lit-program rx-program ere-program
            (choice-program P) (seq-program P) (repeat-program P)
            text-program (control-program P ControlRule))))

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
(struct %lit ([ids : (Vectorof TokenId)]) #:transparent)
(struct %regex ([machine : RegexMachine]) #:transparent)
(struct (A) %choice ([options : (Vectorof A)]) #:transparent)
(struct (A) %seq ([children : (Vectorof A)]) #:transparent)
(struct (A) %repeat ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct %text ([max-tokens : Natural]) #:transparent)
(struct compiled-rule
  ([path : String] [polarity : Symbol] [kind : Symbol]
   [machine : RegexMachine] [end-anchor? : Boolean])
  #:transparent)
(struct (A) %control ([child : A] [rules : (Listof compiled-rule)]) #:transparent)

(define-type Guidance
  (Rec G (U %lit %regex (%choice G) (%seq G) (%repeat G)
            %text (%control G))))

;; One match record per active control occurrence. Aggregation across repeated
;; occurrences and missing branches happens in the weak-observation layer.
(struct weak-match
  ([path : String] [polarity : Symbol] [matched? : Boolean]
   [start-token : Natural] [end-token : Natural])
  #:transparent)

(struct lit-state ([pos : Natural] [len : Natural]) #:transparent)
(struct regex-state ([state : RegexState] [accepting? : Boolean]) #:transparent)
(struct (A) choice-state ([children : (Vectorof A)]) #:transparent)
(struct (A) alternatives-state ([branches : (Vectorof A)]) #:transparent)
(struct (A) seq-state
  ([index : Natural] [children-count : Natural] [child : A]
   [capture-chunks : (Listof (Listof weak-match))] [start : Natural]
   [consumed : Natural] [weak? : Boolean])
  #:transparent)
(struct (A) repeat-state
  ([count : Natural] [min-count : Natural] [max-count : Natural] [child : A]
   [in-item? : Boolean] [capture-chunks : (Listof (Listof weak-match))]
   [start : Natural] [consumed : Natural] [weak? : Boolean])
  #:transparent)
(struct text-state ([count : Natural] [max-tokens : Natural]) #:transparent)
(struct ban-runtime
  ([rule : compiled-rule] [state : RegexState] [latched? : Boolean])
  #:transparent)
(struct (A) control-state
  ([child : A] [rules : (Listof compiled-rule)] [bans : (Listof ban-runtime)]
   [start : Natural] [reversed-ids : TokenIds] [count : Natural] [hard-dead? : Boolean])
  #:transparent)
(struct dead-state ([trace : (Listof Any)]) #:transparent)

(define-type GuidanceState
  (Rec S (U lit-state regex-state (choice-state S) (alternatives-state S) (seq-state S)
            (repeat-state S) text-state (control-state S) dead-state)))

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
                      (ere-pattern-has-end-anchor? (ere-program-pattern pattern)))))

(: compile-guidance (-> Program TokenizeProc RegexVocabulary Guidance))
(define (compile-guidance program tokenize-text vocabulary)
  (let compile : Guidance ([p : Program program] [path : String "root"])
    (cond
      [(lit-program? p) (%lit (list->vector (tokenize-text (lit-program-source p))))]
      [(rx-program? p) (%regex (instantiate-regex-machine (rx-program-regex p) vocabulary))]
      [(ere-program? p) (%regex (instantiate-regex-machine
                                 (ere-full-program (ere-program-pattern p)) vocabulary))]
      [(choice-program? p)
       (%choice (for/vector : (Vectorof Guidance) ([child (in-list (choice-program-options p))]
                                                   [i : Natural (in-naturals)])
                  (compile child (path-child path 'choice i))))]
      [(seq-program? p)
       (%seq (for/vector : (Vectorof Guidance) ([child (in-list (seq-program-children p))]
                                                [i : Natural (in-naturals)])
               (compile child (path-child path 'seq i))))]
      [(repeat-program? p)
       (%repeat (repeat-program-min-count p) (repeat-program-max-count p)
                (compile (repeat-program-item p) (format "~a/repeat" path)))]
      [(text-program? p) (%text (text-program-max-tokens p))]
      [else
       (define cp (assert p control-program?))
       (%control
        (compile (control-program-child cp) (format "~a/control/child" path))
        (for/list : (Listof compiled-rule) ([rule (in-list (control-program-rules cp))]
                                            [i : Natural (in-naturals)])
          (compile-rule rule path i vocabulary)))])))

(: guidance-initial (->* (Guidance) (Natural #:weak? Boolean) GuidanceState))
(define (guidance-initial f [start 0] #:weak? [weak? #t])
  (define raw : GuidanceState
    (cond
      [(%lit? f) (lit-state 0 (vector-length (%lit-ids f)))]
      [(%regex? f)
       (define st (regex-initial (%regex-machine f)))
       (regex-state st (regex-accepting? (%regex-machine f) st))]
      [(%choice? f)
       (choice-state
        (for/vector : (Vectorof GuidanceState) ([g (in-vector (%choice-options f))])
          (guidance-initial g start #:weak? weak?)))]
      [(%seq? f)
       (define children (%seq-children f))
       (if (zero? (vector-length children))
           (error 'seq "empty sequences are unsupported")
           (seq-state 0 (vector-length children)
                      (guidance-initial (vector-ref children 0) start #:weak? weak?)
                      '() start 0 weak?))]
      [(%repeat? f)
       (define child (guidance-initial (%repeat-item f) start #:weak? weak?))
       (when (guidance-accepting? child)
         (error 'repeat "nullable repeated programs are unsupported"))
       (repeat-state 0 (%repeat-min-count f) (%repeat-max-count f) child
                     #f '() start 0 weak?)]
      [(%text? f) (text-state 0 (%text-max-tokens f))]
      [else
       (define control (assert f %control?))
       (control-state
        (guidance-initial (%control-child control) start #:weak? weak?)
        (if weak? (%control-rules control)
            (filter (lambda ([rule : compiled-rule])
                      (eq? (compiled-rule-polarity rule) 'ban))
                    (%control-rules control)))
        (for/list : (Listof ban-runtime) ([rule (in-list (%control-rules control))]
                                          #:when (eq? (compiled-rule-polarity rule) 'ban))
          (ban-runtime rule (regex-initial (compiled-rule-machine rule)) #f))
        start '() 0 #f)]))
  (normalize f raw))

(: guidance-step (-> Guidance GuidanceState TokenId GuidanceState))
(define (guidance-step f st id)
  (cond
    [(alternatives-state? st)
     (make-alternatives-state
      (for/list : (Listof GuidanceState)
                ([branch (in-vector (alternatives-state-branches st))])
        (guidance-step f branch id)))]
    [(guidance-dead? st) st]
    [else (normalize f (step-raw f st id))]))

(: step-raw (-> Guidance GuidanceState TokenId GuidanceState))
(define (step-raw f st id)
  (cond
    [(%lit? f)
     (define s (assert st lit-state?))
     (if (and (< (lit-state-pos s) (lit-state-len s))
              (= id (vector-ref (%lit-ids f) (lit-state-pos s))))
         (lit-state (add1 (lit-state-pos s)) (lit-state-len s))
         (dead-state (list 'lit-dead)))]
    [(%regex? f)
     (define s (assert st regex-state?))
     (define next (regex-step (%regex-machine f) (regex-state-state s) id))
     (if next
         (regex-state next (regex-accepting? (%regex-machine f) next))
         (dead-state (list 'regex-dead)))]
    [(%choice? f)
     (define s (assert st choice-state?))
     (choice-state
      (for/vector : (Vectorof GuidanceState) ([g (in-vector (%choice-options f))]
                                              [child (in-vector (choice-state-children s))])
        (guidance-step g child id)))]
    [(%seq? f)
     (define s (assert st seq-state?))
     (if (>= (seq-state-index s) (seq-state-children-count s))
         (dead-state (list 'seq-terminal))
         (seq-state (seq-state-index s) (seq-state-children-count s)
                    (guidance-step (vector-ref (%seq-children f) (seq-state-index s))
                                   (seq-state-child s) id)
                    (seq-state-capture-chunks s)
                    (seq-state-start s) (add1 (seq-state-consumed s))
                    (seq-state-weak? s)))]
    [(%repeat? f)
     (define s (assert st repeat-state?))
     (if (>= (repeat-state-count s) (repeat-state-max-count s))
         (dead-state (list 'repeat-max))
         (repeat-state (repeat-state-count s) (repeat-state-min-count s)
                       (repeat-state-max-count s)
                       (guidance-step (%repeat-item f) (repeat-state-child s) id)
                       #t (repeat-state-capture-chunks s)
                       (repeat-state-start s) (add1 (repeat-state-consumed s))
                       (repeat-state-weak? s)))]
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
     (define collect?
       (ormap (lambda ([rule : compiled-rule])
                (not (eq? (compiled-rule-polarity rule) 'ban)))
              (control-state-rules s)))
     (control-state next-child (control-state-rules s) next-bans
                    (control-state-start s)
                    (if collect? (cons id (control-state-reversed-ids s)) '())
                    (add1 (control-state-count s))
                    (or (control-state-hard-dead? s)
                        (ormap ban-runtime-latched? next-bans)))]))

(: normalize (-> Guidance GuidanceState GuidanceState))
(define (normalize f st)
  (cond
    [(guidance-dead? st) st]
    [(alternatives-state? st) st]
    [(%seq? f) (normalize-seq f (assert st seq-state?))]
    [(%repeat? f) (normalize-repeat f (assert st repeat-state?))]
    [else st]))

(: normalize-seq (-> (%seq Guidance) (seq-state GuidanceState) GuidanceState))
(define (normalize-seq f st0)
  (define children (%seq-children f))
  (define child (seq-state-child st0))
  (cond
    [(guidance-dead? child) child]
    [(and (guidance-accepting? child)
          (< (add1 (seq-state-index st0)) (vector-length children)))
     (define next-index (add1 (seq-state-index st0)))
     (define advanced
       (seq-state next-index (seq-state-children-count st0)
                  (guidance-initial (vector-ref children next-index)
                                    (+ (seq-state-start st0) (seq-state-consumed st0))
                                    #:weak? (seq-state-weak? st0))
                  (cons (guidance-weak-matches child)
                        (seq-state-capture-chunks st0))
                  (seq-state-start st0) (seq-state-consumed st0) (seq-state-weak? st0)))
     (make-alternatives-state (list st0 (normalize-seq f advanced)))]
    [else st0]))

(: normalize-repeat (-> (%repeat Guidance) (repeat-state GuidanceState) GuidanceState))
(define (normalize-repeat f st)
  (define child (repeat-state-child st))
  (cond
    [(guidance-dead? child) child]
    [(and (repeat-state-in-item? st) (guidance-accepting? child))
     (define count (add1 (repeat-state-count st)))
     (define captures (cons (guidance-weak-matches child)
                            (repeat-state-capture-chunks st)))
     (define completed
       (if (>= count (repeat-state-max-count st))
           (repeat-state count (repeat-state-min-count st) (repeat-state-max-count st)
                         child #f captures (repeat-state-start st)
                         (repeat-state-consumed st) (repeat-state-weak? st))
           (repeat-state count (repeat-state-min-count st) (repeat-state-max-count st)
                         (guidance-initial (%repeat-item f)
                                           (+ (repeat-state-start st) (repeat-state-consumed st))
                                           #:weak? (repeat-state-weak? st))
                         #f captures (repeat-state-start st)
                         (repeat-state-consumed st) (repeat-state-weak? st))))
     (make-alternatives-state (list st completed))]
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
    [(choice-state? st) (for/or : Boolean ([child (in-vector (choice-state-children st))])
                          (guidance-accepting? child))]
    [(alternatives-state? st)
     (for/or : Boolean ([branch (in-vector (alternatives-state-branches st))])
       (guidance-accepting? branch))]
    [(seq-state? st)
     (and (= (seq-state-index st) (sub1 (seq-state-children-count st)))
          (guidance-accepting? (seq-state-child st)))]
    [(repeat-state? st)
     (and (not (repeat-state-in-item? st))
          (>= (repeat-state-count st) (repeat-state-min-count st)))]
    [(text-state? st) #t]
    [(control-state? st)
     (and (not (control-state-hard-dead? st))
          (guidance-accepting? (control-state-child st))
          (not (boundary-ban? st)))]
    [else #f]))

(: guidance-dead? (-> GuidanceState Boolean))
(define (guidance-dead? st)
  (cond [(dead-state? st) #t]
        [(choice-state? st) (for/and : Boolean ([child (in-vector (choice-state-children st))])
                              (guidance-dead? child))]
        [(alternatives-state? st)
         (for/and : Boolean ([branch (in-vector (alternatives-state-branches st))])
           (guidance-dead? branch))]
        [(control-state? st) (or (control-state-hard-dead? st)
                                 (guidance-dead? (control-state-child st)))]
        [else #f]))

(: flatten-alternatives (-> GuidanceState (Listof GuidanceState)))
(define (flatten-alternatives st)
  (if (alternatives-state? st)
      (append-map flatten-alternatives
                  (vector->list (alternatives-state-branches st)))
      (list st)))

(: make-alternatives-state (-> (Listof GuidanceState) GuidanceState))
(define (make-alternatives-state states)
  (define branches
    (remove-duplicates
     (filter (lambda ([st : GuidanceState]) (not (guidance-dead? st)))
             (append-map flatten-alternatives states))
     equal?))
  (cond
    [(null? branches) (dead-state (list 'alternatives-dead))]
    [(null? (cdr branches)) (car branches)]
    [else (alternatives-state (list->vector branches))]))

(: regex-match-ids? (-> RegexMachine TokenIds Boolean))
(define (regex-match-ids? machine ids)
  (let loop ([state : (Option RegexState) (regex-initial machine)] [rest : TokenIds ids])
    (cond [(not state) #f]
          [(null? rest) (regex-accepting? machine state)]
          [else (loop (regex-step machine state (car rest)) (cdr rest))])))

(: current-control-matches (-> (control-state GuidanceState) (Listof weak-match)))
(define (current-control-matches st)
  (define ids (reverse (control-state-reversed-ids st)))
  (append
   (guidance-weak-matches (control-state-child st))
   (for/list : (Listof weak-match) ([rule (in-list (control-state-rules st))]
                                   #:unless (eq? (compiled-rule-polarity rule) 'ban))
     (weak-match (compiled-rule-path rule) (compiled-rule-polarity rule)
                 (regex-match-ids? (compiled-rule-machine rule) ids)
                 (control-state-start st)
                 (+ (control-state-start st) (control-state-count st))))))

(: flatten-chunks (-> (Listof (Listof weak-match)) (Listof weak-match)))
(define (flatten-chunks chunks) (append* (reverse chunks)))

(: accepting-matches (-> (Listof GuidanceState) (Listof weak-match)))
(define (accepting-matches states)
  (remove-duplicates
   (append-map guidance-weak-matches
               (filter guidance-accepting? states))
   equal?))

(: guidance-weak-matches (-> GuidanceState (Listof weak-match)))
(define (guidance-weak-matches st)
  (cond
    [(alternatives-state? st)
     (accepting-matches (vector->list (alternatives-state-branches st)))]
    [(choice-state? st)
     (accepting-matches (vector->list (choice-state-children st)))]
    [(seq-state? st) (append (flatten-chunks (seq-state-capture-chunks st))
                             (guidance-weak-matches (seq-state-child st)))]
    [(repeat-state? st) (append (flatten-chunks (repeat-state-capture-chunks st))
                                (if (repeat-state-in-item? st)
                                    (guidance-weak-matches (repeat-state-child st)) '()))]
    [(control-state? st) (current-control-matches st)]
    [else '()]))

(: guidance-token-domain (-> Guidance GuidanceState TokenDomain))
(define (guidance-token-domain f st)
  (cond
    [(guidance-dead? st) domain-none]
    [(alternatives-state? st)
     (for/fold ([domain : TokenDomain domain-none])
               ([branch (in-vector (alternatives-state-branches st))])
       (domain-union domain (guidance-token-domain f branch)))]
    [(%lit? f)
     (define s (assert st lit-state?))
     (if (< (lit-state-pos s) (lit-state-len s))
         (domain-only (list (vector-ref (%lit-ids f) (lit-state-pos s)))) domain-none)]
    [(%regex? f) (domain-only
                  (regex-allowed-ids (%regex-machine f)
                                     (regex-state-state (assert st regex-state?))))]
    [(%choice? f)
     (define s (assert st choice-state?))
     (for/fold ([domain : TokenDomain domain-none])
               ([child (in-vector (%choice-options f))]
                [child-state (in-vector (choice-state-children s))])
       (if (guidance-dead? child-state) domain
           (domain-union domain (guidance-token-domain child child-state))))]
    [(%seq? f)
     (define s (assert st seq-state?))
     (if (>= (seq-state-index s) (seq-state-children-count s)) domain-none
         (guidance-token-domain
          (vector-ref (%seq-children f) (seq-state-index s)) (seq-state-child s)))]
    [(%repeat? f)
     (define s (assert st repeat-state?))
     (if (>= (repeat-state-count s) (repeat-state-max-count s)) domain-none
         (guidance-token-domain (%repeat-item f) (repeat-state-child s)))]
    [(%text? f)
     (define s (assert st text-state?))
     (if (< (text-state-count s) (text-state-max-tokens s))
         domain-all domain-none)]
    [(%control? f)
     (define g (assert f %control?))
     (define s (assert st control-state?))
     (define base (guidance-token-domain (%control-child g) (control-state-child s)))
     (define blocked
       (remove-duplicates
        (append-map
         (lambda ([ban : ban-runtime])
           (if (compiled-rule-end-anchor? (ban-runtime-rule ban)) '()
               (regex-accepted-ids (compiled-rule-machine (ban-runtime-rule ban))
                                   (ban-runtime-state ban))))
         (control-state-bans s))))
     (domain-subtract base (domain-only blocked))]))

;; Structural metadata and profile validation.
(: indexed-programs (-> (Listof Program) (Listof (Pairof Program Natural))))
(define (indexed-programs programs)
  (for/list : (Listof (Pairof Program Natural)) ([program (in-list programs)]
                                                  [i : Natural (in-naturals)])
    (cons program i)))

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

(: pattern-shape (-> (U lit-program ere-program) Symbol))
(define (pattern-shape p) (if (lit-program? p) 'literal 'ere))

(: program-shape-form (-> Program Any))
(define (program-shape-form p)
  (cond
    [(lit-program? p) '(lit)]
    [(rx-program? p) '(rx)]
    [(ere-program? p) '(ere)]
    [(choice-program? p) (cons 'choice (map program-shape-form (choice-program-options p)))]
    [(seq-program? p) (cons 'seq (map program-shape-form (seq-program-children p)))]
    [(repeat-program? p) (list 'repeat (repeat-program-min-count p)
                               (repeat-program-max-count p)
                               (program-shape-form (repeat-program-item p)))]
    [(text-program? p) (list 'text (text-program-max-tokens p))]
    [else
     (define c (assert p control-program?))
     (list 'control (program-shape-form (control-program-child c))
           (for/list : (Listof Any) ([r (in-list (control-program-rules c))])
             (cond [(prefer-rule? r) (list 'prefer (pattern-shape (prefer-rule-pattern r)))]
                   [(avoid-rule? r) (list 'avoid (pattern-shape (avoid-rule-pattern r)))]
                   [else (list 'ban (pattern-shape (ban-rule-pattern (assert r ban-rule?))))])))]))

(: program-canonical-form (-> Program Any))
(define (program-canonical-form p)
  (cond
    [(lit-program? p) (list 'lit (lit-program-source p))]
    [(rx-program? p) (list 'rx 'extended-pcre)]
    [(ere-program? p) (pattern-form p)]
    [(choice-program? p) (cons 'choice (map program-canonical-form (choice-program-options p)))]
    [(seq-program? p) (cons 'seq (map program-canonical-form (seq-program-children p)))]
    [(repeat-program? p) (list 'repeat (repeat-program-min-count p)
                               (repeat-program-max-count p)
                               (program-canonical-form (repeat-program-item p)))]
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
    [else '()]))

(: program-pwsg-errors (-> Program (Listof String)))
(define (program-pwsg-errors p)
  (define structural
    (let walk : (Listof String) ([node : Program p] [path : String "root"])
      (cond
        [(rx-program? node) (list (format "~a: rx is outside the PWSG profile" path))]
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

(: program-layout-errors (-> Program (Listof String)))
(define (program-layout-errors p) (tail-errors p "root"))
