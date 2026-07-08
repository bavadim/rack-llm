#lang typed/racket/base

(require racket/list
         racket/string
         "private/regex.rkt")

(provide TokenId
         TokenIds
         Logit
         Logits
         ProviderMode
         Score
         Tokenizer
         Provider
         Model
         Filter
         FilterState
         Watcher
         FilterBuilder
         WatcherBuilder
         CandidatePolicy
         tokenizer
         provider
         model
         tokenize
         detokenize
         token-ref
         vocab-size
         fingerprint
         provider-next-logits
         provider-session-supported?
         provider-vocab-size
         provider-mode
         provider-metadata
         model-tokenizer
         model-provider
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
         ban
         weight
         neg-inf
         log-score-add
         log-score-dead?
         log-score>?
         filter-initial
         filter-step
         filter-allowed-ids
         filter-accepting?
         filter-terminal?
         filter-dead?
         filter-score
         filter-potential
         filter-value
         filter-token-ids
         filter-trace
         (struct-out generation-metrics)
         (struct-out generation-result)
         generate
         log-softmax
         sequence-logprob
         sample-id)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
(define-type Logit Real)
(define-type Logits (Vectorof Real))
(define-type ProviderMode (U 'exact-full-vocab 'top-k-approx))

(struct tokenizer-impl
  ([tokenize-proc : (-> String TokenIds)]
   [detokenize-proc : (-> TokenIds String)]
   [token-ref-proc : (-> TokenId String)]
   [vocab-size : Natural]
   [fingerprint : String])
  #:transparent)
(define-type Tokenizer tokenizer-impl)

(: tokenizer
   (-> #:tokenize (-> String TokenIds)
       #:detokenize (-> TokenIds String)
       #:token-ref (-> TokenId String)
       #:vocab-size Natural
       #:fingerprint String
       Tokenizer))
(define (tokenizer #:tokenize tokenize-proc
                   #:detokenize detokenize-proc
                   #:token-ref token-ref-proc
                   #:vocab-size size
                   #:fingerprint fp)
  (tokenizer-impl
   (lambda ([text : String])
     (define ids (tokenize-proc text))
     (check-token-ids 'tokenize ids size)
     ids)
   (lambda ([ids : TokenIds])
     (check-token-ids 'detokenize ids size)
     (detokenize-proc ids))
   (lambda ([id : TokenId])
     (unless (< id size)
       (raise-argument-error 'token-ref (format "token id < ~a" size) id))
     (token-ref-proc id))
   size
   fp))

(: tokenize (-> Tokenizer String TokenIds))
(define (tokenize tok text)
  ((tokenizer-impl-tokenize-proc tok) text))

(: detokenize (-> Tokenizer TokenIds String))
(define (detokenize tok ids)
  ((tokenizer-impl-detokenize-proc tok) ids))

(: token-ref (-> Tokenizer TokenId String))
(define (token-ref tok id)
  ((tokenizer-impl-token-ref-proc tok) id))

(: vocab-size (-> Tokenizer Natural))
(define (vocab-size tok)
  (tokenizer-impl-vocab-size tok))

(: fingerprint (-> Tokenizer String))
(define (fingerprint tok)
  (tokenizer-impl-fingerprint tok))

(: check-token-ids (-> Symbol TokenIds Natural Void))
(define (check-token-ids who ids size)
  (for ([id (in-list ids)])
    (unless (< id size)
      (raise-argument-error who (format "token id < ~a" size) id))))

(struct provider-impl
  ([vocab-size : Natural]
   [next-logits : (-> TokenIds TokenIds Logits)]
   [mode : ProviderMode]
   [metadata : (HashTable Symbol Any)]
   [start-session : (Option (-> TokenIds Any))]
   [next-logits/session : (Option (-> Any Logits))]
   [commit-token! : (Option (-> Any TokenId Void))]
   [end-session! : (Option (-> Any Void))])
  #:transparent)
(define-type Provider provider-impl)

(: provider
   (->* (#:vocab-size Natural
         #:next-logits (-> TokenIds TokenIds Logits))
        (#:mode ProviderMode
         #:metadata (HashTable Symbol Any)
         #:start-session (Option (-> TokenIds Any))
         #:next-logits/session (Option (-> Any Logits))
         #:commit-token! (Option (-> Any TokenId Void))
         #:end-session! (Option (-> Any Void)))
        Provider))
(define (provider #:vocab-size size
                  #:next-logits next-logits-proc
                  #:mode [mode 'exact-full-vocab]
                  #:metadata [metadata (ann (hash) (HashTable Symbol Any))]
                  #:start-session [start-session #f]
                  #:next-logits/session [next-logits/session #f]
                  #:commit-token! [commit-token! #f]
                  #:end-session! [end-session! #f])
  (when (or start-session next-logits/session commit-token! end-session!)
    (unless (and start-session next-logits/session commit-token! end-session!)
      (raise-arguments-error 'provider
                             "session protocol requires all four session callbacks")))
  (provider-impl size next-logits-proc mode metadata
                 start-session next-logits/session commit-token! end-session!))

(: provider-next-logits (-> Provider TokenIds TokenIds Logits))
(define (provider-next-logits p prompt-ids prefix-ids)
  (define logits ((provider-impl-next-logits p) prompt-ids prefix-ids))
  (check-logits 'provider-next-logits logits (provider-impl-vocab-size p))
  logits)

(: provider-session-supported? (-> Provider Boolean))
(define (provider-session-supported? p)
  (and (provider-impl-start-session p)
       (provider-impl-next-logits/session p)
       (provider-impl-commit-token! p)
       (provider-impl-end-session! p)
       #t))

(: provider-vocab-size (-> Provider Natural))
(define (provider-vocab-size p) (provider-impl-vocab-size p))
(: provider-mode (-> Provider ProviderMode))
(define (provider-mode p) (provider-impl-mode p))
(: provider-metadata (-> Provider (HashTable Symbol Any)))
(define (provider-metadata p) (provider-impl-metadata p))

(: check-logits (-> Symbol Logits Natural Void))
(define (check-logits who logits expected-size)
  (unless (= (vector-length logits) expected-size)
    (raise-arguments-error who
                           "logits vector length must match vocabulary"
                           "expected" expected-size
                           "actual" (vector-length logits))))

(struct model
  ([tokenizer : Tokenizer]
   [provider : Provider]
   [metadata : (HashTable Symbol Any)]
   [close! : (-> Void)])
  #:transparent)
(define-type Model model)

;; Regex internals live in private/regex.rkt. main.rkt keeps the public
;; builder facade and tokenizer-specific wiring.

(: instantiate-regex-for-tokenizer (-> RegexProgram Tokenizer RegexMachine))
(define (instantiate-regex-for-tokenizer program tok)
  (define token-texts
    (for/vector : (Vectorof String) ([id : Natural (in-range (vocab-size tok))])
      (token-ref tok id)))
  (instantiate-regex-machine program token-texts))

;; Filter implementation



(define-type Score Real)
(define neg-inf : Real -inf.0)

(struct %lit-filter ([ids : TokenIds]) #:transparent)
(struct %rx-filter ([machine : RegexMachine]) #:transparent)
(struct %pure-filter ([value : Any]) #:transparent)
(struct (A) %choice-filter ([options : (Listof A)]) #:transparent)
(struct (A) %seq-filter ([children : (Listof A)]) #:transparent)
(struct (A) %repeat-filter ([min-count : Natural] [max-count : Natural] [item : A]) #:transparent)
(struct (A) %bind-filter ([first : A] [continue : (-> Any A)]) #:transparent)
(struct (A) %score-filter ([score : Real] [child : A] [ban? : Boolean]) #:transparent)
(struct %text-filter ([max-tokens : Natural] [watchers : (Listof Watcher)]) #:transparent)

(define-type Filter
  (Rec F (U %lit-filter
            %rx-filter
            %pure-filter
            (%choice-filter F)
            (%seq-filter F)
            (%repeat-filter F)
            (%bind-filter F)
            (%score-filter F)
            %text-filter)))

(struct rank-watcher ([score : Real] [ids : TokenIds]) #:transparent)
(struct ban-watcher ([ids : TokenIds]) #:transparent)
(struct weighted-rule ([score : Real] [ids : TokenIds] [source : String]) #:transparent)
(struct weighted-watcher ([rules : (Listof weighted-rule)]) #:transparent)
(define-type Watcher (U rank-watcher ban-watcher weighted-watcher))

(define-type FilterBuilder (-> Tokenizer Filter))
(define-type WatcherBuilder (-> Tokenizer Watcher))

(struct lit-state ([pos : Natural] [len : Natural]) #:transparent)
(struct rx-state ([state : RegexState] [accepting? : Boolean] [terminal? : Boolean]) #:transparent)
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
   [cont-filter : (Option Filter)]
   [ids : TokenIds])
  #:transparent)
(struct (A) score-state ([score : Real] [child : A]) #:transparent)
(struct text-state ([ids : TokenIds] [max-tokens : Natural] [watch-states : (Listof watch-state)]) #:transparent)
(struct dead-state ([ids : TokenIds] [trace : (Listof Any)]) #:transparent)

(define-type FilterState
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

(struct watch-state
  ([watcher : Watcher]
   [ids : TokenIds]
   [matched? : Boolean]
   [dead? : Boolean]
   [score : Real]
   [potential : Real]
   [trace : (Listof Any)])
  #:transparent)

(: log-score-dead? (-> Real Boolean))
(define (log-score-dead? x) (eqv? x neg-inf))

(: log-score-add (-> Real Real Real))
(define (log-score-add a b)
  (if (or (log-score-dead? a) (log-score-dead? b)) neg-inf (+ a b)))

(: log-score>? (-> Real Real Boolean))
(define (log-score>? a b) (> a b))

(: filter-initial (-> Filter FilterState))
(define (filter-initial f)
  (normalize
   f
   (cond
     [(%lit-filter? f) (lit-state 0 (length (%lit-filter-ids f)))]
     [(%rx-filter? f)
      (define initial-rx-state (regex-initial (%rx-filter-machine f)))
      (rx-state initial-rx-state
                (regex-accepting? (%rx-filter-machine f) initial-rx-state)
                (regex-terminal? (%rx-filter-machine f) initial-rx-state))]
     [(%pure-filter? f) (pure-state (%pure-filter-value f))]
     [(%choice-filter? f)
      (choice-state (map filter-initial (%choice-filter-options f)))]
     [(%seq-filter? f)
      (define children (%seq-filter-children f))
      (seq-state 0
                 (length children)
                 (if (null? children) (pure-state (void)) (filter-initial (car children)))
                 0.0
                 (void)
                 '())]
     [(%repeat-filter? f)
      (repeat-state 0
                    (%repeat-filter-min-count f)
                    (%repeat-filter-max-count f)
                    (filter-initial (%repeat-filter-item f))
                    '()
                    0.0
                    '())]
     [(%bind-filter? f)
      (bind-state 'first
                  (filter-initial (%bind-filter-first f))
                  0.0
                  #f
                  '())]
     [(%score-filter? f)
      (score-state (%score-filter-score f)
                   (filter-initial (%score-filter-child f)))]
     [(%text-filter? f)
      (text-state '()
                  (%text-filter-max-tokens f)
                  (map watch-initial (%text-filter-watchers f)))])))

(: filter-step (-> Filter FilterState TokenId FilterState))
(define (filter-step f st id)
  (if (filter-dead? st)
      st
      (let ([next (step-raw f st id)])
        (if (dead-state? next) next (normalize f next)))))

(: step-raw (-> Filter FilterState TokenId FilterState))
(define (step-raw f st id)
  (cond
    [(%lit-filter? f)
     (define s (assert-lit-state st))
     (if (and (< (lit-state-pos s) (length (%lit-filter-ids f)))
              (= id (list-ref (%lit-filter-ids f) (lit-state-pos s))))
         (lit-state (add1 (lit-state-pos s)) (lit-state-len s))
         (dead-state (list id) (list 'lit-dead)))]
    [(%rx-filter? f)
     (define s (assert-rx-state st))
     (define next (regex-step (%rx-filter-machine f) (rx-state-state s) id))
     (if next
         (rx-state next
                   (regex-accepting? (%rx-filter-machine f) next)
                   (regex-terminal? (%rx-filter-machine f) next))
         (dead-state (list id) (list 'rx-dead)))]
    [(%pure-filter? f) (dead-state (list id) (list 'pure-terminal))]
    [(%choice-filter? f)
     (define s (assert-choice-state st))
     (choice-state
      (for/list : (Listof FilterState)
                ([child (in-list (%choice-filter-options f))]
                 [child-state (in-list (choice-state-children s))])
        (filter-step child child-state id)))]
    [(%seq-filter? f)
     (define s (assert-seq-state st))
     (define child-filter (list-ref (%seq-filter-children f) (seq-state-index s)))
     (seq-state (seq-state-index s)
                (seq-state-len s)
                (filter-step child-filter (seq-state-child s) id)
                (seq-state-score s)
                (seq-state-value s)
                (append (seq-state-ids s) (list id)))]
    [(%repeat-filter? f)
     (define s (assert-repeat-state st))
     (if (>= (repeat-state-count s) (%repeat-filter-max-count f))
         (dead-state (append (repeat-state-ids s) (list id)) (list 'repeat-max))
         (repeat-state (repeat-state-count s)
                       (repeat-state-min-count s)
                       (repeat-state-max-count s)
                       (filter-step (%repeat-filter-item f) (repeat-state-child s) id)
                       (repeat-state-values s)
                       (repeat-state-score s)
                       (append (repeat-state-ids s) (list id))))]
    [(%bind-filter? f)
     (define s (assert-bind-state st))
     (define active-filter
       (if (eq? (bind-state-phase s) 'first)
           (%bind-filter-first f)
           (assert (bind-state-cont-filter s) values)))
     (bind-state (bind-state-phase s)
                 (filter-step active-filter (bind-state-child s) id)
                 (bind-state-score s)
                 (bind-state-cont-filter s)
                 (append (bind-state-ids s) (list id)))]
    [(%score-filter? f)
     (define s (assert-score-state st))
     (score-state (score-state-score s)
                  (filter-step (%score-filter-child f) (score-state-child s) id))]
    [(%text-filter? f)
     (define s (assert-text-state st))
     (text-state (append (text-state-ids s) (list id))
                 (text-state-max-tokens s)
                 (map (lambda ([ws : watch-state]) (watch-step ws id))
                      (text-state-watch-states s)))]))

(: normalize (-> Filter FilterState FilterState))
(define (normalize f st)
  (cond
    [(%seq-filter? f) (normalize-seq f (assert-seq-state st))]
    [(%repeat-filter? f) (normalize-repeat f (assert-repeat-state st))]
    [(%bind-filter? f) (normalize-bind f (assert-bind-state st))]
    [(%score-filter? f) (normalize-score f (assert-score-state st))]
    [else st]))

(: normalize-seq (-> (%seq-filter Filter) (seq-state FilterState) FilterState))
(define (normalize-seq f st0)
  (let loop : FilterState ([st : (seq-state FilterState) st0])
    (define children (%seq-filter-children f))
    (cond
      [(null? children) st]
      [(filter-dead? (seq-state-child st))
       (dead-state (seq-state-ids st) (filter-trace (seq-state-child st)))]
      [(filter-accepting? (seq-state-child st))
       (define child-state (seq-state-child st))
       (define next-score (log-score-add (seq-state-score st) (filter-score child-state)))
       (define next-value (filter-value child-state))
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
                            (filter-initial (list-ref children next-index))
                            next-score
                            next-value
                            (seq-state-ids st))))]
      [else st])))

(: normalize-repeat (-> (%repeat-filter Filter) (repeat-state FilterState) FilterState))
(define (normalize-repeat f st0)
  (let loop : FilterState ([st : (repeat-state FilterState) st0])
    (define child-state (repeat-state-child st))
    (cond
      [(filter-dead? child-state)
       (if (>= (repeat-state-count st) (repeat-state-min-count st))
           st
           (dead-state (repeat-state-ids st) (filter-trace child-state)))]
      [(and (filter-accepting? child-state)
            (< (repeat-state-count st) (repeat-state-max-count st)))
       (define next-count (add1 (repeat-state-count st)))
       (define next-values (cons (filter-value child-state) (repeat-state-values st)))
       (define next-score (log-score-add (repeat-state-score st) (filter-score child-state)))
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
                               (filter-initial (%repeat-filter-item f))
                               next-values
                               next-score
                               (repeat-state-ids st))))]
      [else st])))

(: normalize-bind (-> (%bind-filter Filter) (bind-state FilterState) FilterState))
(define (normalize-bind f st)
  (define child-state (bind-state-child st))
  (cond
    [(filter-dead? child-state) (dead-state (bind-state-ids st) (filter-trace child-state))]
    [(and (eq? (bind-state-phase st) 'first) (filter-accepting? child-state))
     (define next-filter ((%bind-filter-continue f) (filter-value child-state)))
     (normalize-bind f
                     (bind-state 'cont
                                 (filter-initial next-filter)
                                 (filter-score child-state)
                                 next-filter
                                 (bind-state-ids st)))]
    [else st]))

(: normalize-score (-> (%score-filter Filter) (score-state FilterState) FilterState))
(define (normalize-score f st)
  (define child-state (score-state-child st))
  (if (and (%score-filter-ban? f) (filter-accepting? child-state))
      (dead-state (filter-token-ids child-state) (list 'ban))
      st))

(: filter-allowed-ids (-> Filter FilterState (Option TokenIds)))
(define (filter-allowed-ids f st)
  (cond
    [(filter-dead? st) '()]
    [(%lit-filter? f)
     (define s (assert-lit-state st))
     (if (< (lit-state-pos s) (length (%lit-filter-ids f)))
         (list (list-ref (%lit-filter-ids f) (lit-state-pos s)))
         '())]
    [(%rx-filter? f)
     (regex-allowed-ids (%rx-filter-machine f) (rx-state-state (assert-rx-state st)))]
    [(%pure-filter? f) '()]
    [(%choice-filter? f)
     (define s (assert-choice-state st))
     (let loop : (Option TokenIds)
       ([children : (Listof Filter) (%choice-filter-options f)]
        [child-states : (Listof FilterState) (choice-state-children s)]
        [ids : TokenIds '()])
       (cond
         [(or (null? children) (null? child-states)) (remove-duplicates ids)]
         [(filter-dead? (car child-states))
          (loop (cdr children) (cdr child-states) ids)]
         [else
          (define child-ids (filter-allowed-ids (car children) (car child-states)))
          (if child-ids
              (loop (cdr children) (cdr child-states) (append ids child-ids))
              #f)]))]
    [(%seq-filter? f)
     (define s (assert-seq-state st))
     (if (>= (seq-state-index s) (length (%seq-filter-children f)))
         '()
         (filter-allowed-ids (list-ref (%seq-filter-children f) (seq-state-index s))
                             (seq-state-child s)))]
    [(%repeat-filter? f)
     (define s (assert-repeat-state st))
     (if (>= (repeat-state-count s) (%repeat-filter-max-count f))
         '()
         (filter-allowed-ids (%repeat-filter-item f) (repeat-state-child s)))]
    [(%bind-filter? f)
     (define s (assert-bind-state st))
     (define active-filter
       (if (eq? (bind-state-phase s) 'first)
           (%bind-filter-first f)
           (assert (bind-state-cont-filter s) values)))
     (filter-allowed-ids active-filter (bind-state-child s))]
    [(%score-filter? f)
     (filter-allowed-ids (%score-filter-child f) (score-state-child (assert-score-state st)))]
    [(%text-filter? f) #f]))

(: filter-accepting? (-> FilterState Boolean))
(define (filter-accepting? st)
  (cond
    [(lit-state? st) (= (lit-state-pos st) (lit-state-len st))]
    [(rx-state? st) (rx-state-accepting? st)]
    [(pure-state? st) #t]
    [(choice-state? st) (ormap filter-accepting? (choice-state-children st))]
    [(seq-state? st) (>= (seq-state-index st) (seq-state-len st))]
    [(repeat-state? st) (>= (repeat-state-count st) (repeat-state-min-count st))]
    [(bind-state? st) (and (eq? (bind-state-phase st) 'cont)
                           (filter-accepting? (bind-state-child st)))]
    [(score-state? st) (filter-accepting? (score-state-child st))]
    [(text-state? st) (>= (length (text-state-ids st)) (text-state-max-tokens st))]
    [(dead-state? st) #f]))

(: filter-terminal? (-> Filter FilterState Boolean))
(define (filter-terminal? f st)
  (cond
    [(filter-dead? st) #t]
    [(%lit-filter? f) (filter-accepting? st)]
    [(%rx-filter? f) (rx-state-terminal? (assert-rx-state st))]
    [(%pure-filter? f) #t]
    [(%choice-filter? f)
     (define s (assert-choice-state st))
     (for/and : Boolean ([child (in-list (%choice-filter-options f))]
                         [child-state (in-list (choice-state-children s))]
                         #:unless (filter-dead? child-state))
       (filter-terminal? child child-state))]
    [(%seq-filter? f) (and (seq-state? st) (>= (seq-state-index st) (length (%seq-filter-children f))))]
    [(%repeat-filter? f) (and (repeat-state? st) (>= (repeat-state-count st) (%repeat-filter-max-count f)))]
    [(%bind-filter? f)
     (define s (assert-bind-state st))
     (and (eq? (bind-state-phase s) 'cont)
          (filter-terminal? (assert (bind-state-cont-filter s) values)
                            (bind-state-child s)))]
    [(%score-filter? f) (filter-terminal? (%score-filter-child f)
                                         (score-state-child (assert-score-state st)))]
    [(%text-filter? f) (and (text-state? st) (>= (length (text-state-ids st)) (%text-filter-max-tokens f)))]))

(: filter-dead? (-> FilterState Boolean))
(define (filter-dead? st)
  (cond
    [(dead-state? st) #t]
    [(choice-state? st) (andmap filter-dead? (choice-state-children st))]
    [(score-state? st) (filter-dead? (score-state-child st))]
    [(text-state? st) (ormap watch-state-dead? (text-state-watch-states st))]
    [else #f]))

(: filter-score (-> FilterState Real))
(define (filter-score st)
  (cond
    [(dead-state? st) neg-inf]
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:unless (filter-dead? s))
       (max best (filter-score s)))]
    [(seq-state? st) (seq-state-score st)]
    [(repeat-state? st) (repeat-state-score st)]
    [(bind-state? st) (log-score-add (bind-state-score st)
                                     (filter-score (bind-state-child st)))]
    [(score-state? st)
     (define child (score-state-child st))
     (if (filter-accepting? child)
         (log-score-add (filter-score child) (score-state-score st))
         (filter-score child))]
    [(text-state? st) (watch-states-score (text-state-watch-states st))]
    [else 0.0]))

(: filter-accepted-score (-> FilterState Real))
(define (filter-accepted-score st)
  (cond
    [(not (filter-accepting? st)) neg-inf]
    [(dead-state? st) neg-inf]
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:when (filter-accepting? s))
       (max best (filter-accepted-score s)))]
    [(seq-state? st) (seq-state-score st)]
    [(repeat-state? st) (repeat-state-score st)]
    [(bind-state? st) (log-score-add (bind-state-score st)
                                     (filter-accepted-score (bind-state-child st)))]
    [(score-state? st)
     (log-score-add (filter-accepted-score (score-state-child st))
                    (score-state-score st))]
    [(text-state? st) (watch-states-score (text-state-watch-states st))]
    [else 0.0]))

(: filter-potential (-> FilterState Real))
(define (filter-potential st)
  (cond
    [(choice-state? st)
     (for/fold ([best : Real neg-inf])
               ([s (in-list (choice-state-children st))]
                #:unless (filter-dead? s))
       (max best (filter-potential s)))]
    [(text-state? st) (watch-states-potential (text-state-watch-states st))]
    [(score-state? st) (filter-potential (score-state-child st))]
    [else 0.0]))

(: filter-value (-> FilterState Any))
(define (filter-value st)
  (cond
    [(pure-state? st) (pure-state-value st)]
    [(choice-state? st)
     (define accepted (filter filter-accepting? (choice-state-children st)))
     (and (pair? accepted)
          (filter-value
           (argmax filter-accepted-score accepted)))]
    [(seq-state? st) (seq-state-value st)]
    [(repeat-state? st) (reverse (repeat-state-values st))]
    [(bind-state? st) (filter-value (bind-state-child st))]
    [(text-state? st) (text-state-ids st)]
    [else (void)]))

(: filter-token-ids (-> FilterState TokenIds))
(define (filter-token-ids st)
  (cond
    [(seq-state? st) (seq-state-ids st)]
    [(repeat-state? st) (repeat-state-ids st)]
    [(bind-state? st) (bind-state-ids st)]
    [(text-state? st) (text-state-ids st)]
    [(dead-state? st) (dead-state-ids st)]
    [else '()]))

(: filter-trace (-> FilterState (Listof Any)))
(define (filter-trace st)
  (cond
    [(dead-state? st) (dead-state-trace st)]
    [(text-state? st) (append-map watch-state-trace (text-state-watch-states st))]
    [else '()]))

(: watch-initial (-> Watcher watch-state))
(define (watch-initial w)
  (watch-state w '() #f #f 0.0 0.0 '()))

(: watch-step (-> watch-state TokenId watch-state))
(define (watch-step st id)
  (if (or (watch-state-matched? st) (watch-state-dead? st))
      st
      (watch-evaluate st (append (watch-state-ids st) (list id)))))

(: watch-evaluate (-> watch-state TokenIds watch-state))
(define (watch-evaluate st ids)
  (define w (watch-state-watcher st))
  (cond
    [(rank-watcher? w)
     (define matched? (contains-subsequence? ids (rank-watcher-ids w)))
     (define potential (if matched? 0.0 (rank-potential ids (rank-watcher-ids w) (rank-watcher-score w))))
     (watch-state w ids matched? #f
                  (if matched? (rank-watcher-score w) 0.0)
                  potential
                  (if matched? (list (list 'rank (rank-watcher-score w) (rank-watcher-ids w))) '()))]
    [(ban-watcher? w)
     (define matched? (contains-subsequence? ids (ban-watcher-ids w)))
     (watch-state w ids matched? matched?
                  (if matched? neg-inf 0.0)
                  0.0
                  (if matched? (list (list 'ban neg-inf (ban-watcher-ids w))) '()))]
    [(weighted-watcher? w)
     (define matched-rules
       (filter (lambda ([rule : weighted-rule])
                 (contains-subsequence? ids (weighted-rule-ids rule)))
               (weighted-watcher-rules w)))
     (watch-state w ids (pair? matched-rules) #f
                  (for/fold ([score : Real 0.0])
                            ([rule (in-list matched-rules)])
                    (log-score-add score (weighted-rule-score rule)))
                  0.0
                  (for/list : (Listof Any) ([rule (in-list matched-rules)])
                    (list 'weight (weighted-rule-score rule) (weighted-rule-source rule))))]))

(: watch-states-score (-> (Listof watch-state) Real))
(define (watch-states-score states)
  (for/fold ([score : Real 0.0])
            ([s (in-list states)])
    (if (watch-state-dead? s)
        neg-inf
        (log-score-add score (watch-state-score s)))))

(: watch-states-potential (-> (Listof watch-state) Real))
(define (watch-states-potential states)
  (for/sum : Real ([s (in-list states)])
    (watch-state-potential s)))

(: contains-subsequence? (-> TokenIds TokenIds Boolean))
(define (contains-subsequence? xs needle)
  (cond
    [(null? needle) #t]
    [(< (length xs) (length needle)) #f]
    [else
     (for/or : Boolean ([start (in-range (add1 (- (length xs) (length needle))))])
       (equal? needle (take (drop xs start) (length needle))))]))

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

(: assert-lit-state (-> FilterState lit-state))
(define (assert-lit-state v) (assert v lit-state?))
(: assert-rx-state (-> FilterState rx-state))
(define (assert-rx-state v) (assert v rx-state?))
(: assert-choice-state (-> FilterState (choice-state FilterState)))
(define (assert-choice-state v) (assert v choice-state?))
(: assert-seq-state (-> FilterState (seq-state FilterState)))
(define (assert-seq-state v) (assert v seq-state?))
(: assert-repeat-state (-> FilterState (repeat-state FilterState)))
(define (assert-repeat-state v) (assert v repeat-state?))
(: assert-bind-state (-> FilterState (bind-state FilterState)))
(define (assert-bind-state v) (assert v bind-state?))
(: assert-score-state (-> FilterState (score-state FilterState)))
(define (assert-score-state v) (assert v score-state?))
(: assert-text-state (-> FilterState text-state))
(define (assert-text-state v) (assert v text-state?))

;; Public filter builders. They are immutable descriptions that compile to
;; token-native filters only when the caller applies them to a tokenizer.


(: lit (-> String FilterBuilder))
(define (lit source)
  (lambda ([tok : Tokenizer])
    (%lit-filter (tokenize tok source))))

(: rx (-> String FilterBuilder))
(define (rx pattern)
  (define program (parse-regex-program pattern))
  (lambda ([tok : Tokenizer])
    (%rx-filter (instantiate-regex-for-tokenizer program tok))))

(: pure (-> Any FilterBuilder))
(define (pure value)
  (lambda ([_tok : Tokenizer])
    (%pure-filter value)))

(: choice (-> (Listof FilterBuilder) FilterBuilder))
(define (choice options)
  (lambda ([tok : Tokenizer])
    (%choice-filter
     (for/list : (Listof Filter) ([option (in-list options)])
       (option tok)))))

(: seq (-> (Listof FilterBuilder) FilterBuilder))
(define (seq children)
  (lambda ([tok : Tokenizer])
    (%seq-filter
     (for/list : (Listof Filter) ([child (in-list children)])
       (child tok)))))

(: repeat (-> Natural Natural FilterBuilder FilterBuilder))
(define (repeat min-count max-count item)
  (lambda ([tok : Tokenizer])
    (%repeat-filter min-count max-count (item tok))))

(: bind (-> FilterBuilder (-> Any FilterBuilder) FilterBuilder))
(define (bind first continue)
  (lambda ([tok : Tokenizer])
    (%bind-filter
     (first tok)
     (lambda ([value : Any])
       ((continue value) tok)))))

(: score (-> Real FilterBuilder Boolean FilterBuilder))
(define (score amount child ban?)
  (lambda ([tok : Tokenizer])
    (%score-filter amount (child tok) ban?)))

(: text (-> Natural (Listof WatcherBuilder) FilterBuilder))
(define (text max-tokens watchers)
  (lambda ([tok : Tokenizer])
    (%text-filter
     max-tokens
     (for/list : (Listof Watcher) ([watcher (in-list watchers)])
       (watcher tok)))))

(: rank (-> Real String WatcherBuilder))
(define (rank amount source)
  (lambda ([tok : Tokenizer])
    (rank-watcher amount (tokenize tok source))))

(: ban (-> String WatcherBuilder))
(define (ban source)
  (lambda ([tok : Tokenizer])
    (ban-watcher (tokenize tok source))))

(: weight (-> (Listof String) (Listof (Pairof Real String)) WatcherBuilder))
(define (weight samples specs)
  (when (null? samples)
    (raise-argument-error 'weight "non-empty list of strings" samples))
  (when (null? specs)
    (raise-argument-error 'weight "non-empty watcher spec list" specs))
  (lambda ([tok : Tokenizer])
    (weighted-watcher
     (for/list : (Listof weighted-rule) ([spec (in-list specs)])
       (define source (cdr spec))
       (define pos (add1 (count (lambda ([sample : String])
                                  (string-contains? sample source))
                                samples)))
       (define neg (add1 (- (length samples) (sub1 pos))))
       (define raw : Real (assert (log (/ pos neg)) real?))
       (define oriented
         (if (negative? (car spec)) (- (abs raw)) (abs raw)))
       (weighted-rule oriented (tokenize tok source) source)))))


;; Generation



(define-type CandidatePolicy (U 'full-vocab 'allowed-only (List 'top-k Positive-Integer)))

(struct generation-metrics
  ([steps : Natural]
   [generated-tokens : Natural]
   [llm-calls : Natural]
   [dead-token-count : Natural]
   [provider-mode : ProviderMode]
   [vocab-size : Natural]
   [candidate-policy : CandidatePolicy]
   [candidate-count-total : Natural]
   [candidate-count-per-step : (Listof Natural)]
   [filter-step-calls : Natural]
   [provider-session? : Boolean])
  #:transparent)

(struct generation-result
  ([status : Symbol]
   [reason : (Option String)]
   [token-ids : TokenIds]
   [value : Any]
   [lm-logprob : Real]
   [filter-score : Real]
   [total-score : Real]
   [hard-ok? : Boolean]
   [steps : Natural]
   [generated-tokens : Natural]
   [latency-ms : Real]
   [trace : (Listof Any)]
   [metrics : generation-metrics])
  #:transparent)

(struct token-selection
  ([id : (Option TokenId)]
   [lm-logprob : Real]
   [adjustment : Real]
   [dead-count : Natural]
   [next-state : (Option FilterState)]
   [candidate-count : Natural])
  #:transparent)

(: generate
   (->* (Provider TokenIds Filter)
        (#:beta Real
         #:lambda Real
         #:temperature Real
         #:seed (Option Integer)
         #:deadline-ms (Option Real)
         #:max-tokens Natural
         #:candidate-policy CandidatePolicy)
        generation-result))
(define (generate p prompt-ids f
                  #:beta [beta 1.0]
                  #:lambda [lambda-weight 0.5]
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128]
                  #:candidate-policy [candidate-policy 'full-vocab])
  (define started (current-inexact-milliseconds))
  (define rng (make-rng seed))
  (define session? (provider-session-supported? p))
  (define session : (Option Any)
    (and session? ((assert (provider-impl-start-session p) values) prompt-ids)))
  (: next-logits (-> TokenIds Logits))
  (define (next-logits prefix-ids)
    (if session?
        (let ([logits ((assert (provider-impl-next-logits/session p) values)
                       (assert session values))])
          (check-logits 'provider-impl-next-logits/session logits (provider-vocab-size p))
          logits)
        (provider-next-logits p prompt-ids prefix-ids)))
  (: commit! (-> TokenId Void))
  (define (commit! id)
    (when session?
      ((assert (provider-impl-commit-token! p) values) (assert session values) id)))
  (: end-session! (-> Void))
  (define (end-session!)
    (when session?
      ((assert (provider-impl-end-session! p) values) (assert session values))))
  (: finish (-> generation-result generation-result))
  (define (finish result)
    (end-session!)
    result)
  (let loop ([step : Natural 0]
             [prefix-ids : TokenIds '()]
             [state : FilterState (filter-initial f)]
             [last-score : Real 0.0]
             [last-potential : Real 0.0]
             [lm-score : Real 0.0]
             [llm-calls : Natural 0]
             [dead-count : Natural 0]
             [candidate-total : Natural 0]
             [candidate-counts : (Listof Natural) '()])
    (cond
      [(deadline-expired? started deadline-ms)
       (finish
        (make-result 'error-budget "deadline exhausted" prefix-ids #f lm-score
                     (filter-score state) beta #f step started
                     p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                     #:trace (filter-trace state)))]
      [(or (filter-dead? state)
           (and (filter-accepting? state) (filter-terminal? f state)))
       (finish
       (if (and (not (filter-dead? state)) (filter-accepting? state))
            (make-result 'found #f prefix-ids (filter-value state) lm-score
                         (filter-accepted-score state) beta #t step started
                         p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                         #:trace (filter-trace state))
            (make-result 'not-found-hard "filter is dead" prefix-ids #f lm-score neg-inf
                         beta #f step started
                         p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                         #:trace (filter-trace state))))]
      [(>= step max-tokens)
       (finish
        (if (filter-accepting? state)
            (make-result 'found #f prefix-ids (filter-value state) lm-score
                         (filter-accepted-score state) beta #t step started
                         p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                         #:trace (filter-trace state))
            (make-result 'not-found-budget "token budget exhausted" prefix-ids #f lm-score
                         (filter-score state) beta #f step started
                         p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                         #:trace (filter-trace state))))]
      [else
       (define logits (next-logits prefix-ids))
       (define logprobs (log-softmax logits))
       (define selection
         (select-token f state logits logprobs candidate-policy
                       last-score last-potential beta lambda-weight temperature rng))
       (define considered (token-selection-candidate-count selection))
       (cond
         [(not (token-selection-id selection))
          (finish
           (make-result 'not-found-hard "no provider token keeps the filter valid"
                        prefix-ids #f lm-score neg-inf beta #f step started
                        p session? candidate-policy (add1 llm-calls)
                        (+ dead-count (token-selection-dead-count selection))
                        (+ candidate-total considered)
                        (cons considered candidate-counts)))]
         [else
          (define id (assert (token-selection-id selection) exact-nonnegative-integer?))
          (define next-state (assert (token-selection-next-state selection) values))
          (commit! id)
          (loop (add1 step)
                (append prefix-ids (list id))
                next-state
                (filter-score next-state)
                (filter-potential next-state)
                (log-score-add lm-score (token-selection-lm-logprob selection))
                (add1 llm-calls)
                (+ dead-count (token-selection-dead-count selection))
                (+ candidate-total considered)
                (cons considered candidate-counts))])])))

(: select-token
   (-> Filter FilterState Logits Logits CandidatePolicy Real Real Real Real Real Pseudo-Random-Generator token-selection))
(define (select-token f state logits logprobs candidate-policy
                      last-score last-potential beta lambda-weight temperature rng)
  (unless (> temperature 0.0)
    (raise-argument-error 'generate "positive temperature" temperature))
  (define ids (candidate-ids f state logits candidate-policy))
  (define-values (best-id best-score best-lm best-adjustment best-state dead)
    (for/fold ([best-id : (Option TokenId) #f]
               [best-score : Real -inf.0]
               [best-lm : Real -inf.0]
               [best-adjustment : Real 0.0]
               [best-state : (Option FilterState) #f]
               [dead : Natural 0])
              ([id (in-list ids)])
      (define raw (vector-ref logits id))
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
            (define sample-score (+ (/ adjusted temperature) (gumbel rng)))
            (if (> sample-score best-score)
                (values id sample-score (vector-ref logprobs id) adjustment next-state dead)
                (values best-id best-score best-lm best-adjustment best-state dead))])])))
  (token-selection best-id best-lm best-adjustment dead best-state (length ids)))

(: candidate-ids (-> Filter FilterState Logits CandidatePolicy TokenIds))
(define (candidate-ids f state logits policy)
  (define all-ids : TokenIds
    (for/list : TokenIds ([id : Natural (in-range (vector-length logits))]) id))
  (cond
    [(eq? policy 'allowed-only) (or (filter-allowed-ids f state) all-ids)]
    [(eq? policy 'full-vocab) all-ids]
    [else (top-k-ids logits (cadr policy))]))

(: top-k-ids (-> Logits Positive-Integer TokenIds))
(define (top-k-ids logits k)
  (define pairs
    (for/list : (Listof (Pairof TokenId Real))
              ([logit (in-vector logits)] [id : Natural (in-naturals)])
      (cons id logit)))
  (define sorted
    (sort pairs
          (lambda ([a : (Pairof TokenId Real)] [b : (Pairof TokenId Real)])
            (> (cdr a) (cdr b)))))
  (for/list : TokenIds ([pair (in-list (take sorted (min k (vector-length logits))))])
    (car pair)))

(: sequence-logprob (-> Provider TokenIds TokenIds Real))
(define (sequence-logprob p prompt-ids ids)
  (let loop ([remaining : TokenIds ids] [prefix : TokenIds '()] [score : Real 0.0])
    (cond
      [(null? remaining) score]
      [else
       (define logits (provider-next-logits p prompt-ids prefix))
       (define logprobs (log-softmax logits))
       (define id (car remaining))
       (loop (cdr remaining)
             (append prefix (list id))
             (log-score-add score (vector-ref logprobs id)))])))

(: log-softmax (-> Logits Logits))
(define (log-softmax logits)
  (define max-logit
    (for/fold ([best : Real -inf.0])
              ([x (in-vector logits)])
      (max best x)))
  (if (log-score-dead? max-logit)
      (for/vector : Logits ([x (in-vector logits)]) -inf.0)
      (let ([log-z (+ max-logit
                      (log (for/sum : Real ([x (in-vector logits)])
                             (if (log-score-dead? x) 0.0 (exp (- x max-logit))))))])
        (for/vector : Logits ([x (in-vector logits)])
          (if (log-score-dead? x) -inf.0 (assert (- x log-z) real?))))))

(: sample-id (-> Logits Pseudo-Random-Generator Real TokenId))
(define (sample-id adjusted-logits rng temperature)
  (define-values (id _score)
    (for/fold ([best-id : (Option TokenId) #f] [best-score : Real -inf.0])
              ([logit (in-vector adjusted-logits)]
               [id : Natural (in-naturals)])
      (define score (+ (/ logit temperature) (gumbel rng)))
      (if (and (not (log-score-dead? logit))
               (> score best-score))
          (values id score)
          (values best-id best-score))))
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
  (define u
    (parameterize ([current-pseudo-random-generator rng])
      (max 1e-12 (min (- 1.0 1e-12) (random)))))
  (assert (- (log (- (log u)))) real?))

(: make-result
   (->* (Symbol (Option String) TokenIds Any Real Real Real Boolean Natural Real
                Provider Boolean CandidatePolicy Natural Natural Natural (Listof Natural))
        (#:trace (Listof Any))
        generation-result))
(define (make-result status reason ids value lm-score f-score beta hard-ok? steps started
                     p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                     #:trace [trace '()])
  (generation-result status reason ids value lm-score f-score
                     (combined-score lm-score f-score beta)
                     hard-ok? steps steps
                     (- (current-inexact-milliseconds) started)
                     trace
                     (generation-metrics steps
                                         steps
                                         llm-calls
                                         dead-count
                                         (provider-mode p)
                                         (provider-vocab-size p)
                                         candidate-policy
                                         candidate-total
                                         (reverse candidate-counts)
                                         candidate-total
                                         session?)))

(: combined-score (-> Real Real Real Real))
(define (combined-score lm local beta)
  (if (or (log-score-dead? lm) (log-score-dead? local))
      neg-inf
      (+ lm (* beta local))))

(: deadline-expired? (-> Real (Option Real) Boolean))
(define (deadline-expired? started deadline-ms)
  (and deadline-ms
       (>= (- (current-inexact-milliseconds) started) deadline-ms)))
