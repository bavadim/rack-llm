#lang racket/base

(require racket/list
         racket/match
         racket/string
         "core.rkt"
         "provider.rkt"
         "weight.rkt")

(provide check
         finite-candidates
         sampling-supported?
         (struct-out rt-state)
         guide-init
         guide-init-runtime
         guide-step
         guide-step-runtime
         guide-finish
         dead?
         done?
         state-score
         state-potential
         state-value
         state-trace
         runtime-token-count
         runtime-allowed-next-ids
         runtime-watch-ids
         runtime-forced-string
         watcher-score
         watcher-trace
         watch-init
         watch-step
         watch-dead?
         watch-score
         watch-potential
         watch-trace)

(struct parsed (pos value score) #:transparent)
(struct rt-state
  (guide text status score potential value trace impl token-count)
  #:transparent)

(struct lit-impl (literal offset) #:transparent)
(struct rx-impl (pattern) #:transparent)
(struct pure-impl () #:transparent)
(struct ranked-impl (bonus child) #:transparent)
(struct seq-impl (children index child prefix-score prefix-value provider) #:transparent)
(struct repeat-impl (min max item count child values score provider) #:transparent)
(struct bind-impl (phase first cont child first-score cont-guide provider) #:transparent)
(struct candidate (text value score ids) #:transparent)
(struct select-impl (candidates trie node) #:transparent)
(struct trie-node (children done) #:transparent)
(struct text-impl (max-tokens until watchers) #:transparent)
(struct watch-state (kind expr weight matched? dead? buffer score potential trace children data)
  #:transparent)

(define default-finite-candidate-limit 10000)

(define (guide-init g)
  (guide-init-runtime g #f))

(define (guide-init-runtime g [provider #f])
  (init-guide (ensure-guide 'guide-init g) provider))

(define (guide-step state token)
  (guide-step-runtime state #f token))

(define (guide-step-runtime state token-id token)
  (unless (string? token)
    (raise-argument-error 'guide-step-runtime "string token" token))
  (if (dead? state)
      state
      (step-state state token-id token)))

(define (guide-finish state)
  (if (done? state)
      state
      (struct-copy rt-state state
                   [status 'dead]
                   [score neg-inf]
                   [trace (cons 'unfinished (rt-state-trace state))])))

(define (dead? state)
  (eq? (rt-state-status state) 'dead))

(define (done? state)
  (eq? (rt-state-status state) 'done))

(define (state-score state)
  (rt-state-score state))

(define (state-potential state)
  (rt-state-potential state))

(define (state-value state)
  (rt-state-value state))

(define (state-trace state)
  (rt-state-trace state))

(define (runtime-token-count state)
  (rt-state-token-count state))

(define (sampling-supported? g)
  (define guide (ensure-guide 'sampling-supported? g))
  (match (guide-kind guide)
    ['text
     (match-define (list _max-tokens until _watchers) (guide-data guide))
     (not until)]
    ['rx #f]
    ['pure #t]
    ['lit #t]
    ['ranked-guide
     (match-define (list _score expr) (guide-data guide))
     (sampling-supported? expr)]
    ['seq (andmap sampling-supported? (guide-data guide))]
    ['select (andmap sampling-supported? (guide-data guide))]
    ['repeat
     (match-define (list _min _max item) (guide-data guide))
     (sampling-supported? item)]
    ['bind #t]
    [_ #f]))

(define (init-guide guide provider)
  (match (guide-kind guide)
    ['pure
     (rt-state guide "" 'done 0.0 0.0 (guide-data guide) '(done)
               (pure-impl) 0)]
    ['lit
     (define literal (guide-data guide))
     (rt-state guide "" (if (zero? (string-length literal)) 'done 'live)
               0.0 0.0 (and (zero? (string-length literal)) (void))
               (if (zero? (string-length literal)) '(done) '(live))
               (lit-impl literal 0)
               0)]
    ['rx
     (rt-state guide "" 'live 0.0 0.0 #f '(live) (rx-impl (guide-data guide)) 0)]
    ['ranked-guide
     (match-define (list bonus expr) (guide-data guide))
     (define child (init-guide (ensure-guide 'ranked-guide expr) provider))
     (ranked-state guide bonus child)]
    ['seq
     (define children (guide-data guide))
     (seq-normalize guide
                    (seq-impl children 0
                              (and (pair? children)
                                   (init-guide (car children) provider))
                              0.0
                              (void)
                              provider)
                    "")]
    ['select
     (define raw (finite-candidates guide
                                    #:max-finite-candidates
                                    default-finite-candidate-limit))
     (cond
       [(or (eq? raw 'too-many) (not raw))
        (rt-state guide "" 'dead neg-inf 0.0 #f
                  (list 'unsupported-select) (select-impl '() #f #f) 0)]
       [else
        (define cs
          (for/list ([c (in-list raw)])
            (match-define (list s value score) c)
            (candidate s value score
                       (and provider
                            (with-handlers ([exn:fail? (lambda (_exn) #f)])
                              (tokenize provider s))))))
        (define trie (and provider (build-trie cs)))
        (select-state guide cs trie (and trie trie) "")])]
    ['repeat
     (match-define (list min-count max-count item) (guide-data guide))
     (when (and (< 0 max-count)
                (done? (init-guide item provider)))
       (raise-arguments-error 'repeat
                              "zero-length repeat item is unsupported for sampling"))
     (repeat-normalize guide
                       (repeat-impl min-count
                                    max-count
                                    item
                                    0
                                    (init-guide item provider)
                                    '()
                                    0.0
                                    provider)
                       "")]
    ['bind
     (match-define (cons first cont) (guide-data guide))
     (bind-normalize guide
                     (bind-impl 'first first cont (init-guide first provider)
                                0.0 #f provider)
                     "")]
    ['text
     (match-define (list max-tokens until watchers) (guide-data guide))
     (define watch-states (map watch-init watchers))
     (rt-state guide "" 'live 0.0 (watch-states-potential watch-states)
               #f '() (text-impl max-tokens until watch-states) 0)]
    [kind
     (rt-state guide "" 'dead neg-inf 0.0 #f
               (list (list 'unsupported kind)) #f 0)]))

(define (step-state state token-id token)
  (match (rt-state-impl state)
    [(lit-impl literal offset)
     (lit-step state literal offset token)]
    [(rx-impl pattern)
     (rx-step state pattern token)]
    [(ranked-impl bonus child)
     (ranked-state (rt-state-guide state)
                   bonus
                   (guide-step-runtime child token-id token))]
    [(seq-impl _children _index child _prefix-score _prefix-value _provider)
     (seq-step state child token-id token)]
    [(select-impl candidates trie node)
     (select-step state candidates trie node token-id token)]
    [(repeat-impl _min _max _item _count child _values _score _provider)
     (repeat-step state child token-id token)]
    [(bind-impl _phase _first _cont child _first-score _cont-guide _provider)
     (bind-step state child token-id token)]
    [(text-impl max-tokens until watchers)
     (text-step state max-tokens until watchers token)]
    [_ state]))

(define (lit-step state literal offset token)
  (define end (+ offset (string-length token)))
  (cond
    [(and (<= end (string-length literal))
          (string=? token (substring literal offset end)))
     (define status (if (= end (string-length literal)) 'done 'live))
     (rt-state (rt-state-guide state)
               (string-append (rt-state-text state) token)
               status
               0.0
               0.0
               (and (eq? status 'done) (void))
               (list status)
               (lit-impl literal end)
               (add1 (rt-state-token-count state)))]
    [else
     (dead-state state token)]))

(define (rx-step state pattern token)
  (define text (string-append (rt-state-text state) token))
  (cond
    [(regexp-full-match? pattern text)
     (rt-state (rt-state-guide state) text 'done 0.0 0.0 text '(done)
               (rx-impl pattern) (add1 (rt-state-token-count state)))]
    [(rx-prefix-viable? pattern text)
     (rt-state (rt-state-guide state) text 'live 0.0 0.0 #f '(live)
               (rx-impl pattern) (add1 (rt-state-token-count state)))]
    [else (dead-state state token)]))

(define (ranked-state guide bonus child)
  (define status (rt-state-status child))
  (define child-score (rt-state-score child))
  (define score
    (cond
      [(dead? child) neg-inf]
      [(done? child) (log-score-add bonus child-score)]
      [else child-score]))
  (rt-state guide
            (rt-state-text child)
            status
            score
            (rt-state-potential child)
            (rt-state-value child)
            (rt-state-trace child)
            (ranked-impl bonus child)
            (rt-state-token-count child)))

(define (seq-step state child token-id token)
  (define impl (rt-state-impl state))
  (match-define (seq-impl children index _ prefix-score prefix-value provider) impl)
  (seq-normalize (rt-state-guide state)
                 (seq-impl children index
                           (guide-step-runtime child token-id token)
                           prefix-score
                           prefix-value
                           provider)
                 (string-append (rt-state-text state) token)))

(define (seq-normalize guide impl text)
  (let loop ([impl impl])
    (match-define (seq-impl children index child prefix-score prefix-value provider) impl)
    (cond
      [(null? children)
       (rt-state guide text 'done prefix-score 0.0 prefix-value '(done) impl 0)]
      [(not child)
       (rt-state guide text 'done prefix-score 0.0 prefix-value '(done) impl 0)]
      [(dead? child)
       (rt-state guide text 'dead neg-inf 0.0 #f (rt-state-trace child) impl
                 (rt-state-token-count child))]
      [(done? child)
       (define next-index (add1 index))
       (define next-score (log-score-add prefix-score (state-score child)))
       (define next-value (state-value child))
       (if (>= next-index (length children))
           (rt-state guide text 'done next-score 0.0 next-value '(done)
                     (seq-impl children next-index child next-score next-value provider)
                     (rt-state-token-count child))
           (loop (seq-impl children
                           next-index
                           (init-guide (list-ref children next-index) provider)
                           next-score
                           next-value
                           provider)))]
      [else
       (rt-state guide text 'live
                 (log-score-add prefix-score (state-score child))
                 (state-potential child)
                 #f
                 (state-trace child)
                 impl
                 (rt-state-token-count child))])))

(define (select-step state candidates trie node token-id token)
  (cond
    [(and trie token-id)
     (define child (hash-ref (trie-node-children node) token-id #f))
     (if child
         (select-state (rt-state-guide state)
                       candidates
                       trie
                       child
                       (string-append (rt-state-text state) token)
                       (add1 (rt-state-token-count state)))
         (dead-state state token))]
    [else
     (select-state (rt-state-guide state)
                   candidates
                   trie
                   node
                   (string-append (rt-state-text state) token)
                   (add1 (rt-state-token-count state)))]))

(define (select-state guide candidates trie node text [token-count 0])
  (define exact
    (filter (lambda (c) (string=? text (candidate-text c))) candidates))
  (define live?
    (or (and trie node (not (hash-empty? (trie-node-children node))))
        (ormap (lambda (c) (string-prefix-of? text (candidate-text c))) candidates)))
  (cond
    [(pair? exact)
     (define best (argmax candidate-score exact))
     (rt-state guide text 'done (candidate-score best) 0.0 (candidate-value best)
               '(done) (select-impl candidates trie node) token-count)]
    [live?
     (rt-state guide text 'live 0.0 0.0 #f '(live)
               (select-impl candidates trie node) token-count)]
    [else
     (rt-state guide text 'dead neg-inf 0.0 #f '(dead)
               (select-impl candidates trie node) token-count)]))

(define (repeat-step state child token-id token)
  (define impl (rt-state-impl state))
  (match-define (repeat-impl min-count max-count item count child0 values score provider) impl)
  (cond
    [(>= count max-count) (dead-state state token)]
    [else
     (repeat-normalize (rt-state-guide state)
                       (repeat-impl min-count max-count item count
                                    (guide-step-runtime child0 token-id token)
                                    values
                                    score
                                    provider)
                       (string-append (rt-state-text state) token))]))

(define (repeat-normalize guide impl text)
  (match-define (repeat-impl min-count max-count item count child values score provider) impl)
  (cond
    [(dead? child)
     (rt-state guide text 'dead neg-inf 0.0 #f (state-trace child) impl
               (rt-state-token-count child))]
    [(done? child)
     (define next-count (add1 count))
     (define next-values (cons (state-value child) values))
     (define next-score (log-score-add score (state-score child)))
     (define next-impl
       (repeat-impl min-count max-count item next-count
                    (if (< next-count max-count) (init-guide item provider) child)
                    next-values
                    next-score
                    provider))
     (rt-state guide text
               (if (>= next-count min-count) 'done 'live)
               next-score
               0.0
               (and (>= next-count min-count) (reverse next-values))
               '(done)
               next-impl
               (rt-state-token-count child))]
    [else
     (rt-state guide text
               (if (>= count min-count) 'done 'live)
               score
               (state-potential child)
               (and (>= count min-count) (reverse values))
               (state-trace child)
               impl
               (rt-state-token-count child))]))

(define (bind-step state child token-id token)
  (bind-normalize (rt-state-guide state)
                  (struct-copy bind-impl (rt-state-impl state)
                               [child (guide-step-runtime child token-id token)])
                  (string-append (rt-state-text state) token)))

(define (bind-normalize guide impl text)
  (match-define (bind-impl phase first cont child first-score cont-guide provider) impl)
  (cond
    [(dead? child)
     (rt-state guide text 'dead neg-inf 0.0 #f (state-trace child) impl
               (rt-state-token-count child))]
    [(and (eq? phase 'first) (done? child))
     (define next-guide (cont (state-value child)))
     (bind-normalize guide
                     (bind-impl 'cont first cont
                                (init-guide next-guide provider)
                                (state-score child)
                                next-guide
                                provider)
                     text)]
    [(eq? phase 'cont)
     (rt-state guide text
               (rt-state-status child)
               (log-score-add first-score (state-score child))
               (state-potential child)
               (state-value child)
               (state-trace child)
               impl
               (rt-state-token-count child))]
    [else
     (rt-state guide text 'live (state-score child) (state-potential child)
               #f (state-trace child) impl (rt-state-token-count child))]))

(define (text-step state max-tokens until watchers token)
  (cond
    [until
     (rt-state (rt-state-guide state)
               (string-append (rt-state-text state) token)
               'dead neg-inf 0.0 #f
               (list 'unsupported-until)
               (rt-state-impl state)
               (add1 (rt-state-token-count state)))]
    [else
     (define next-watchers (map (lambda (w) (watch-step w token)) watchers))
     (define token-count (add1 (rt-state-token-count state)))
     (define text (string-append (rt-state-text state) token))
     (define dead-watch (ormap watch-dead? next-watchers))
     (cond
       [dead-watch
        (rt-state (rt-state-guide state) text 'dead neg-inf 0.0 #f
                  (watch-states-trace next-watchers)
                  (text-impl max-tokens until next-watchers)
                  token-count)]
       [(> token-count max-tokens)
        (rt-state (rt-state-guide state) text 'dead neg-inf 0.0 #f
                  (list 'budget-dead)
                  (text-impl max-tokens until next-watchers)
                  token-count)]
       [else
        (define score (watch-states-score next-watchers))
        (define status (if (>= token-count max-tokens) 'done 'live))
        (rt-state (rt-state-guide state)
                  text
                  status
                  score
                  (watch-states-potential next-watchers)
                  (and (eq? status 'done) text)
                  (watch-states-trace next-watchers)
                  (text-impl max-tokens until next-watchers)
                  token-count)])]))

(define (dead-state state token)
  (rt-state (rt-state-guide state)
            (string-append (rt-state-text state) token)
            'dead
            neg-inf
            0.0
            #f
            '(dead)
            (rt-state-impl state)
            (add1 (rt-state-token-count state))))

(define (runtime-allowed-next-ids state)
  (match (rt-state-impl state)
    [(select-impl _candidates trie node)
     (and trie node (hash-keys (trie-node-children node)))]
    [(ranked-impl _ child) (runtime-allowed-next-ids child)]
    [(seq-impl _ _ child _ _ _) (and child (runtime-allowed-next-ids child))]
    [(bind-impl _ _ _ child _ _ _) (and child (runtime-allowed-next-ids child))]
    [_ #f]))

(define (runtime-watch-ids state provider)
  (match (rt-state-impl state)
    [(text-impl _ _ watchers)
     (remove-duplicates
      (append-map (lambda (w) (watch-ids w provider)) watchers))]
    [(ranked-impl _ child) (runtime-watch-ids child provider)]
    [(seq-impl _ _ child _ _ _) (if child (runtime-watch-ids child provider) '())]
    [(bind-impl _ _ _ child _ _ _) (if child (runtime-watch-ids child provider) '())]
    [_ '()]))

(define (runtime-forced-string state)
  (match (rt-state-impl state)
    [(lit-impl literal offset)
     (and (< offset (string-length literal))
          (substring literal offset))]
    [(ranked-impl _ child) (runtime-forced-string child)]
    [(seq-impl _ _ child _ _ _) (and child (runtime-forced-string child))]
    [(bind-impl _ _ _ child _ _ _) (and child (runtime-forced-string child))]
    [_ #f]))

(define (build-trie candidates)
  (define with-ids (filter candidate-ids candidates))
  (and (= (length with-ids) (length candidates))
       (for/fold ([root (trie-node (hash) '())])
                 ([c (in-list candidates)])
         (trie-insert root (candidate-ids c) c))))

(define (trie-insert node ids c)
  (cond
    [(null? ids)
     (trie-node (trie-node-children node)
                (cons c (trie-node-done node)))]
    [else
     (define id (car ids))
     (define old-child
       (hash-ref (trie-node-children node) id (lambda () (trie-node (hash) '()))))
     (define new-child (trie-insert old-child (cdr ids) c))
     (trie-node (hash-set (trie-node-children node) id new-child)
                (trie-node-done node))]))

(define (watch-init w)
  (cond
    [(ranked? w)
     (watch-state 'rank (ranked-expr w) (ranked-score w)
                  #f #f "" 0.0 0.0 '() '() #f)]
    [(banned? w)
     (watch-state 'ban (banned-expr w) neg-inf
                  #f #f "" 0.0 0.0 '() '() #f)]
    [(and (watch? w) (eq? (watch-kind w) 'weighted))
     (define observer (watch-data w))
     (watch-state 'weighted #f 0.0 #f #f "" 0.0 0.0 '()
                  (for/list ([rule (in-list (weighted-observer-rules observer))])
                    (watch-state 'weight-rule
                                 (weighted-rule-expr rule)
                                 (weighted-rule-weight rule)
                                 #f #f "" 0.0 0.0 '() '() rule))
                  observer)]
    [(watch? w)
     (watch-state (watch-kind w) (watch-data w) 0.0 #f #f "" 0.0 0.0 '() '() (watch-data w))]
    [else (raise-argument-error 'watch-init "watcher" w)]))

(define (watch-step state token)
  (match (watch-state-kind state)
    ['rank (rank-watch-step state token)]
    ['ban (ban-watch-step state token)]
    ['weight-rule (rank-watch-step state token)]
    ['weighted
     (define children
       (map (lambda (child) (watch-step child token))
            (watch-state-children state)))
     (watch-state 'weighted #f 0.0 #f (ormap watch-dead? children) ""
                  (watch-states-score children)
                  (watch-states-potential children)
                  (watch-states-trace children)
                  children
                  (watch-state-data state))]
    [_ state]))

(define (rank-watch-step state token)
  (if (watch-state-matched? state)
      state
      (let* ([expr (watch-state-expr state)]
             [buffer (bounded-buffer (watch-state-buffer state) token expr)]
             [matched? (monitor-match? expr buffer)]
             [score (if matched? (watch-state-weight state) 0.0)]
             [potential (if matched? 0.0 (watch-progress-potential expr buffer (watch-state-weight state)))]
             [trace (if matched?
                        (list (watch-trace-entry state))
                        '())])
        (struct-copy watch-state state
                     [matched? matched?]
                     [buffer buffer]
                     [score score]
                     [potential potential]
                     [trace trace]))))

(define (ban-watch-step state token)
  (if (watch-state-dead? state)
      state
      (let* ([expr (watch-state-expr state)]
             [buffer (bounded-buffer (watch-state-buffer state) token expr)]
             [matched? (monitor-match? expr buffer)])
        (struct-copy watch-state state
                     [matched? matched?]
                     [dead? matched?]
                     [buffer buffer]
                     [score (if matched? neg-inf 0.0)]
                     [trace (if matched? (list (watch-trace-entry state)) '())]))))

(define (watch-dead? state)
  (watch-state-dead? state))

(define (watch-score state)
  (watch-state-score state))

(define (watch-potential state)
  (watch-state-potential state))

(define (watch-trace state)
  (watch-state-trace state))

(define (watch-states-score states)
  (for/fold ([score 0.0])
            ([state (in-list states)])
    (if (watch-dead? state)
        neg-inf
        (log-score-add score (watch-score state)))))

(define (watch-states-potential states)
  (for/sum ([state (in-list states)])
    (watch-potential state)))

(define (watch-states-trace states)
  (append-map watch-trace states))

(define (watch-trace-entry state)
  (match (watch-state-kind state)
    ['rank (list 'rank (watch-state-weight state) (watch-state-expr state))]
    ['ban (list 'ban neg-inf (watch-state-expr state))]
    ['weight-rule
     (define rule (watch-state-data state))
     (list 'weight
           (weighted-rule-weight rule)
           (weighted-rule-expr rule)
           (list 'pos-prob (weighted-rule-pos-prob rule))
           (list 'neg-prob (weighted-rule-neg-prob rule)))]
    [_ (list 'watch (watch-state-kind state))]))

(define (watch-ids state provider)
  (define literal (extract-literal-core (watch-state-expr state)))
  (cond
    [(not literal)
     (append-map (lambda (child) (watch-ids child provider))
                 (watch-state-children state))]
    [else
     (with-handlers ([exn:fail? (lambda (_exn) '())])
       (tokenize provider literal))]))

(define (bounded-buffer old token expr)
  (define keep
    (max 64
         (let ([literal (extract-literal-core expr)])
           (if literal (* 2 (string-length literal)) 64))))
  (define next (string-append old token))
  (if (> (string-length next) keep)
      (substring next (- (string-length next) keep))
      next))

(define (watch-progress-potential expr buffer weight)
  (define literal (extract-literal-core expr))
  (cond
    [(or (not literal) (zero? (string-length literal))) 0.0]
    [else
     (define progress
       (/ (longest-prefix-suffix literal buffer)
          (string-length literal)))
     (* weight progress)]))

(define (longest-prefix-suffix literal s)
  (for/fold ([best 0])
            ([n (in-range 1 (add1 (string-length literal)))])
    (define suffix-start (- (string-length s) n))
    (if (and (>= suffix-start 0)
             (string=? (substring literal 0 n)
                       (substring s suffix-start)))
        n
        best)))

(define (extract-literal-core expr)
  (cond
    [(string? expr) expr]
    [(guide? expr)
     (match (guide-kind expr)
       ['lit (guide-data expr)]
       ['rx #f]
       [_ #f])]
    [else #f]))

(define (watcher-score watchers chunk)
  (define states
    (for/list ([w (in-list watchers)])
      (watch-step (watch-init w) chunk)))
  (if (ormap watch-dead? states)
      (values #f neg-inf)
      (values #t (watch-states-score states))))

(define (watcher-trace watchers text)
  (define states
    (for/list ([w (in-list watchers)])
      (watch-step (watch-init w) text)))
  (watch-states-trace states))

(define (monitor-match? expr chunk)
  (cond
    [(string? expr) (string-contains? chunk expr)]
    [(guide? expr)
     (match (guide-kind expr)
       ['lit (string-contains? chunk (guide-data expr))]
       ['rx (regexp-match? (guide-data expr) chunk)]
       [else (raise-argument-error 'rank "lit, rx, or string" expr)])]
    [else (raise-argument-error 'rank "lit, rx, or string" expr)]))

(define (string-prefix-of? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (rx-prefix-viable? pattern text)
  (cond
    [(zero? (string-length text)) #t]
    [(equal? pattern #px"[0-9]+")
     (andmap char-numeric? (string->list text))]
    [(equal? pattern #px"[a-z]")
     (and (= (string-length text) 1)
          (char<=? #\a (string-ref text 0) #\z))]
    [(equal? pattern #px"[a-z]+")
     (andmap (lambda (c) (char<=? #\a c #\z)) (string->list text))]
    [(equal? pattern #px"[A-Za-z]+")
     (andmap char-alphabetic? (string->list text))]
    [else #t]))

(define (regexp-full-match? pattern s)
  (define m (regexp-match pattern s))
  (and m (pair? m) (equal? (car m) s)))

(define (check g s)
  (define started-ms (current-inexact-milliseconds))
  (define guide (ensure-guide 'check g))
  (define parses
    (filter (lambda (p) (= (parsed-pos p) (string-length s)))
            (parse-guide guide s 0)))
  (if (null? parses)
      (make-check-result guide s #f #f neg-inf started-ms)
      (let ([best (argmax parsed-score parses)])
        (make-check-result guide s #t (parsed-value best) (parsed-score best) started-ms))))

(define (make-check-result guide text ok? value score started-ms)
  (define trace
    (if ok?
        (append (check-trace guide text ok? score)
                (list (list 'final-value value)))
        (check-trace guide text ok? score)))
  (check-result ok?
                value
                score
                ok?
                trace
                (if ok? '() trace)
                (filter watcher-trace-entry? trace)
                (hash 'rule-time-ms (- (current-inexact-milliseconds) started-ms))))

(define (check-trace guide text ok? score)
  (cond
    [(eq? (guide-kind guide) 'text)
     (match-define (list _max-tokens _until watchers) (guide-data guide))
     (watcher-trace watchers text)]
    [ok? (list (list 'check 'matched score))]
    [else (list (list 'check 'mismatch neg-inf))]))

(define (watcher-trace-entry? event)
  (and (pair? event)
       (memq (car event) '(rank ban watch weight))))

(define (parse-guide g s pos)
  (define gg (ensure-guide 'parse-guide g))
  (match (guide-kind gg)
    ['pure (list (parsed pos (guide-data gg) 0.0))]
    ['lit (parse-lit (guide-data gg) s pos)]
    ['rx (parse-rx (guide-data gg) s pos)]
    ['seq (parse-seq (guide-data gg) s pos)]
    ['select (append-map (lambda (x) (parse-guide x s pos)) (guide-data gg))]
    ['repeat
     (match-define (list min-count max-count item) (guide-data gg))
     (parse-repeat min-count max-count item s pos)]
    ['bind
     (match-define (cons first cont) (guide-data gg))
     (append-map
      (lambda (p)
        (define next (cont (parsed-value p)))
        (for/list ([q (in-list (parse-guide next s (parsed-pos p)))])
          (parsed (parsed-pos q)
                  (parsed-value q)
                  (log-score-add (parsed-score p) (parsed-score q)))))
      (parse-guide first s pos))]
    ['ranked-guide
     (match-define (list score expr) (guide-data gg))
     (for/list ([p (in-list (parse-guide expr s pos))])
       (parsed (parsed-pos p)
               (parsed-value p)
               (log-score-add score (parsed-score p))))]
    ['text
     (match-define (list max-tokens until watchers) (guide-data gg))
     (define max-end (min (string-length s) (+ pos max-tokens)))
     (for/list ([end (in-range pos (add1 max-end))]
                #:do [(define chunk (substring s pos end))
                      (define-values (ok? score) (watcher-score watchers chunk))]
                #:when ok?
                #:when (or (not until) (pair? (parse-guide until s end))))
       (parsed end chunk score))]
    [kind (raise-arguments-error 'check "unknown guide kind" "kind" kind)]))

(define (parse-lit literal s pos)
  (define end (+ pos (string-length literal)))
  (if (and (<= end (string-length s))
           (string=? literal (substring s pos end)))
      (list (parsed end (void) 0.0))
      '()))

(define (parse-rx pattern s pos)
  (for/list ([end (in-range pos (add1 (string-length s)))]
             #:do [(define chunk (substring s pos end))]
             #:when (regexp-full-match? pattern chunk))
    (parsed end chunk 0.0)))

(define (parse-seq guides s pos)
  (for/fold ([states (list (parsed pos (void) 0.0))])
            ([g (in-list guides)])
    (append-map
     (lambda (state)
       (for/list ([p (in-list (parse-guide g s (parsed-pos state)))])
         (parsed (parsed-pos p)
                 (parsed-value p)
                 (log-score-add (parsed-score state) (parsed-score p)))))
     states)))

(define (parse-repeat min-count max-count item s pos)
  (let loop ([count 0] [pos pos] [values '()] [score 0.0])
    (define done
      (if (>= count min-count)
          (list (parsed pos (reverse values) score))
          '()))
    (cond
      [(= count max-count) done]
      [else
       (append
        done
        (append-map
         (lambda (p)
           (if (= (parsed-pos p) pos)
               '()
               (loop (add1 count)
                     (parsed-pos p)
                     (cons (parsed-value p) values)
                     (log-score-add score (parsed-score p)))))
         (parse-guide item s pos)))])))

(define (finite-candidates g #:max-finite-candidates [limit default-finite-candidate-limit])
  (unless (exact-positive-integer? limit)
    (raise-argument-error 'finite-candidates "positive exact integer limit" limit))
  (define remaining limit)
  (define (charge xs)
    (cond
      [(not xs) #f]
      [(eq? xs 'too-many) 'too-many]
      [(> (length xs) remaining) 'too-many]
      [else (set! remaining (- remaining (length xs))) xs]))
  (define (go x)
    (define gg (ensure-guide 'finite-candidates x))
    (match (guide-kind gg)
      ['pure (charge (list (list "" (guide-data gg) 0.0)))]
      ['lit (charge (list (list (guide-data gg) (void) 0.0)))]
      ['ranked-guide
       (match-define (list score expr) (guide-data gg))
       (define cs (go expr))
       (if (list? cs)
           (charge
            (for/list ([c (in-list cs)])
              (match-define (list s value base-score) c)
              (list s value (log-score-add score base-score))))
           cs)]
      ['select
       (let loop ([items (guide-data gg)] [acc '()])
         (cond
           [(null? items) (charge (reverse acc))]
           [else
            (define cs (go (car items)))
            (cond
              [(list? cs) (loop (cdr items) (append (reverse cs) acc))]
              [else cs])]))]
      ['seq
       (let loop ([items (guide-data gg)] [acc (list (list "" (void) 0.0))])
         (cond
           [(not acc) #f]
           [(null? items) (charge acc)]
           [else
            (define nexts (go (car items)))
            (cond
              [(not (list? nexts)) nexts]
              [else
               (define combined
                 (for*/list ([left (in-list acc)]
                             [right (in-list nexts)])
                   (match-define (list ls _lv lscore) left)
                   (match-define (list rs rv rscore) right)
                   (list (string-append ls rs) rv (log-score-add lscore rscore))))
               (if (> (length combined) remaining)
                   'too-many
                   (loop (cdr items) combined))])]))]
      ['bind
       (match-define (cons first cont) (guide-data gg))
       (define firsts (go first))
       (and (list? firsts)
            (let loop ([items firsts] [acc '()])
              (cond
                [(null? items) (charge (reverse acc))]
                [else
                 (match-define (list s value score) (car items))
                 (define nexts (go (cont value)))
                 (cond
                   [(not (list? nexts)) nexts]
                   [else
                    (loop (cdr items)
                          (append
                           (reverse
                            (for/list ([next (in-list nexts)])
                              (match-define (list ns nv nscore) next)
                              (list (string-append s ns)
                                    nv
                                    (log-score-add score nscore))))
                           acc))])])))]
      ['repeat
       (match-define (list min-count max-count item) (guide-data gg))
       (define item-candidates (go item))
       (and (list? item-candidates)
            (letrec ([combine
                      (lambda (n)
                        (cond
                          [(zero? n) (list (list "" '() 0.0))]
                          [else
                           (define tail (combine (sub1 n)))
                           (define out
                             (for*/list ([head (in-list item-candidates)]
                                         [rest (in-list tail)])
                               (match-define (list hs hv hscore) head)
                               (match-define (list ts tv tscore) rest)
                               (list (string-append hs ts)
                                     (cons hv tv)
                                     (log-score-add hscore tscore))))
                           (if (> (length out) remaining) 'too-many out)]))])
              (let loop ([n min-count] [acc '()])
                (cond
                  [(> n max-count) (charge (reverse acc))]
                  [else
                   (define cs (combine n))
                   (cond
                     [(list? cs) (loop (add1 n) (append (reverse cs) acc))]
                     [else cs])]))))]
      [else #f]))
  (go g))
