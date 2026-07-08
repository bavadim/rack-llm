#lang typed/racket/base

(require racket/list
         "regex.rkt")

(provide Score
         Filter
         FilterState
         Watcher
         neg-inf
         log-score-add
         log-score-dead?
         log-score>?
         (rename-out [%lit-filter make-lit-filter]
                     [%rx-filter make-rx-filter]
                     [%pure-filter make-pure-filter]
                     [%choice-filter make-choice-filter]
                     [%seq-filter make-seq-filter]
                     [%repeat-filter make-repeat-filter]
                     [%bind-filter make-bind-filter]
                     [%score-filter make-score-filter]
                     [%text-filter make-text-filter]
                     [rank-watcher make-rank-watcher]
                     [ban-watcher make-ban-watcher]
                     [weighted-rule make-weighted-rule]
                     [weighted-watcher make-weighted-watcher])
         filter-initial
         filter-step
         filter-allowed-ids
         filter-accepting?
         filter-terminal?
         filter-dead?
         filter-score
         filter-accepted-score
         filter-potential
         filter-value
         filter-token-ids
         filter-trace
         filter-fill-token-adjustments!)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
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

(: filter-fill-token-adjustments!
   (-> Filter FilterState (Vectorof Real) Real Real Boolean))
(define (filter-fill-token-adjustments! f st weights beta lambda-weight)
  (cond
    [(and (%text-filter? f) (text-state? st))
     (define states (text-state-watch-states st))
     (if (andmap text-fast-watch-supported? states)
         (let ()
           (define default-local-delta
             (for/sum : Real ([ws (in-list states)])
               (watch-default-local-delta ws lambda-weight)))
           (fill-real-vector! weights (* beta default-local-delta))
           (for ([ws (in-list states)])
             (fill-watch-token-adjustments! ws weights beta lambda-weight))
           #t)
         #f)]
    [else #f]))

(: fill-real-vector! (-> (Vectorof Real) Real Void))
(define (fill-real-vector! xs value)
  (for ([i : Natural (in-range (vector-length xs))])
    (vector-set! xs i value)))

(: text-fast-watch-supported? (-> watch-state Boolean))
(define (text-fast-watch-supported? st)
  (define w (watch-state-watcher st))
  (or (rank-watcher? w)
      (ban-watcher? w)))

(: watch-default-local-delta (-> watch-state Real Real))
(define (watch-default-local-delta st lambda-weight)
  (define w (watch-state-watcher st))
  (cond
    [(or (watch-state-matched? st)
         (watch-state-dead? st))
     0.0]
    [(rank-watcher? w)
     (* lambda-weight (- (watch-state-potential st)))]
    [(ban-watcher? w) 0.0]
    [else 0.0]))

(: fill-watch-token-adjustments! (-> watch-state (Vectorof Real) Real Real Void))
(define (fill-watch-token-adjustments! st weights beta lambda-weight)
  (define w (watch-state-watcher st))
  (unless (or (watch-state-matched? st)
              (watch-state-dead? st))
    (cond
      [(rank-watcher? w)
       (fill-rank-token-adjustments! st w weights beta lambda-weight)]
      [(ban-watcher? w)
       (fill-ban-token-adjustments! st w weights)]
      [else (void)])))

(: fill-rank-token-adjustments!
   (-> watch-state rank-watcher (Vectorof Real) Real Real Void))
(define (fill-rank-token-adjustments! st watcher weights beta lambda-weight)
  (define needle (rank-watcher-ids watcher))
  (unless (null? needle)
    (define candidate-ids
      (remove-duplicates
       (for/list : TokenIds ([n : Natural (in-range 1 (add1 (length needle)))]
                             #:when (suffix-matches-prefix?
                                      (watch-state-ids st)
                                      needle
                                      (assert (sub1 n) exact-nonnegative-integer?)))
         (list-ref needle (assert (sub1 n) exact-nonnegative-integer?)))))
    (define default-local-delta (watch-default-local-delta st lambda-weight))
    (for ([id (in-list candidate-ids)])
      (define next-ids (append (watch-state-ids st) (list id)))
      (define matched? (contains-subsequence? next-ids needle))
      (define next-score (if matched? (rank-watcher-score watcher) 0.0))
      (define next-potential
        (if matched?
            0.0
            (rank-potential next-ids needle (rank-watcher-score watcher))))
      (define local-delta
        (+ (- next-score (watch-state-score st))
           (* lambda-weight (- next-potential (watch-state-potential st)))))
      (add-token-adjustment! weights id (* beta (- local-delta default-local-delta))))))

(: fill-ban-token-adjustments! (-> watch-state ban-watcher (Vectorof Real) Void))
(define (fill-ban-token-adjustments! st watcher weights)
  (define needle (ban-watcher-ids watcher))
  (unless (null? needle)
    (when (suffix-matches-prefix? (watch-state-ids st) needle
                                  (assert (sub1 (length needle)) exact-nonnegative-integer?))
      (vector-set! weights (last needle) neg-inf))))

(: add-token-adjustment! (-> (Vectorof Real) TokenId Real Void))
(define (add-token-adjustment! weights id delta)
  (define current (vector-ref weights id))
  (unless (log-score-dead? current)
    (vector-set! weights id (+ current delta))))

(: suffix-matches-prefix? (-> TokenIds TokenIds Natural Boolean))
(define (suffix-matches-prefix? ids needle count)
  (cond
    [(zero? count) #t]
    [(> count (length ids)) #f]
    [else (equal? (take-right ids count) (take needle count))]))

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

(module+ test
  (require typed/rackunit)

  (test-case "text fast path fills adjustments without crashing"
    (define f
      (%text-filter 3
                    (list (rank-watcher 10.0 '(1 2))
                          (ban-watcher '(3)))))
    (define st (filter-initial f))
    (define weights : (Vectorof Real) (make-vector 5 0.0))
    (check-true (filter-fill-token-adjustments! f st weights 2.0 1.0))
    (check-true (> (vector-ref weights 1) 0.0))
    (check-equal? (vector-ref weights 3) neg-inf)))
