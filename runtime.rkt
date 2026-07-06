#lang racket/base

(require racket/list
         racket/match
         racket/string
         "core.rkt"
         "weight.rkt")

(provide check
         finite-candidates
         (struct-out rt-state)
         guide-init
         guide-step
         guide-finish
         dead?
         done?
         state-score
         state-potential
         state-value
         state-trace
         watcher-score
         watcher-trace)

(struct parsed (pos value score) #:transparent)
(struct rt-state (guide text status score potential value trace) #:transparent)

(define (guide-init g)
  (runtime-state (ensure-guide 'guide-init g) ""))

(define (guide-step state token)
  (runtime-state (rt-state-guide state)
                 (string-append (rt-state-text state) token)))

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

(define (runtime-state guide text)
  (case (guide-kind guide)
    [(lit) (lit-runtime-state guide text)]
    [(rx) (rx-runtime-state guide text)]
    [(seq select repeat pure bind ranked-guide)
     (define finite (finite-candidates guide))
     (if (pair? finite)
         (finite-runtime-state guide finite text)
         (closed-check-runtime-state guide text))]
    [(text) (text-runtime-state guide text)]
    [else (open-runtime-state guide text)]))

(define (lit-runtime-state guide text)
  (define literal (guide-data guide))
  (cond
    [(string=? text literal)
     (rt-state guide text 'done 0.0 0.0 (void) (list 'done))]
    [(string-prefix-of? text literal)
     (rt-state guide text 'live 0.0 0.0 #f (list 'live))]
    [else
     (rt-state guide text 'dead neg-inf 0.0 #f (list 'dead))]))

(define (rx-runtime-state guide text)
  (define pattern (guide-data guide))
  (cond
    [(regexp-full-match? pattern text)
     (rt-state guide text 'done 0.0 0.0 text (list 'done))]
    [(rx-prefix-viable? pattern text)
     (rt-state guide text 'live 0.0 0.0 #f (list 'live))]
    [else
     (rt-state guide text 'dead neg-inf 0.0 #f (list 'dead))]))

(define (closed-check-runtime-state guide text)
  (define checked (check guide text))
  (if (check-result-ok? checked)
      (rt-state guide text 'done (check-result-guide-score checked) 0.0
                (check-result-value checked)
                (list 'done))
      (rt-state guide text 'dead neg-inf 0.0 #f (list 'dead))))

(define (finite-runtime-state guide candidates text)
  (define exact
    (filter (lambda (candidate)
              (match-define (list s _value _score) candidate)
              (string=? s text))
            candidates))
  (cond
    [(pair? exact)
     (match-define (list _s value score) (argmax third exact))
     (rt-state guide text 'done score 0.0 value (list 'done))]
    [(ormap (lambda (candidate)
              (match-define (list s _value _score) candidate)
              (string-prefix-of? text s))
            candidates)
     (rt-state guide text 'live 0.0 0.0 #f (list 'live))]
    [else
     (rt-state guide text 'dead neg-inf 0.0 #f (list 'dead))]))

(define (open-runtime-state guide text)
  (define checked (check guide text))
  (if (check-result-ok? checked)
      (rt-state guide text 'done (check-result-guide-score checked) 0.0
                (check-result-value checked)
                (list 'done))
      (if (eq? (guide-kind guide) 'text)
          (rt-state guide text 'dead neg-inf 0.0 #f (list 'dead))
          (rt-state guide text 'live 0.0 0.0 #f (list 'live)))))

(define (text-runtime-state guide text)
  (match-define (list max-tokens until watchers) (guide-data guide))
  (cond
    [(> (string-length text) max-tokens)
     (rt-state guide text 'dead neg-inf 0.0 #f (list 'budget-dead))]
    [else
     (define-values (ok? score) (watcher-score watchers text))
     (define trace (watcher-trace watchers text))
     (cond
       [(not ok?) (rt-state guide text 'dead neg-inf 0.0 #f trace)]
       [(text-finished? until text max-tokens)
        (rt-state guide text 'done score 0.0 text trace)]
       [else (rt-state guide text 'live score 0.0 #f trace)])]))

(define (text-finished? until text max-tokens)
  (cond
    [until (pair? (parse-guide until text (string-length text)))]
    [else (>= (string-length text) max-tokens)]))

(define (watcher-trace watchers text)
  (append-map
   (lambda (w)
     (cond
       [(and (watch? w) (eq? (watch-kind w) 'weighted))
        (for/list ([rule (in-list (weighted-observer-rules (watch-data w)))]
                   #:when (monitor-match? (weighted-rule-expr rule) text))
          (list 'weight
                (weighted-rule-weight rule)
                (weighted-rule-expr rule)
                (list 'pos-prob (weighted-rule-pos-prob rule))
                (list 'neg-prob (weighted-rule-neg-prob rule))))]
       [(watcher-matched? w text)
        (list
         (cond
           [(ranked? w) (list 'rank (ranked-score w) (ranked-expr w))]
           [(banned? w) (list 'ban neg-inf (banned-expr w))]
           [(watch? w) (list 'watch (watch-kind w))]
           [else (list 'unknown)]))]
       [else '()]))
   watchers))

(define (watcher-matched? w text)
  (cond
    [(ranked? w) (monitor-match? (ranked-expr w) text)]
    [(banned? w) (monitor-match? (banned-expr w) text)]
    [(watch? w) (not (eq? (watch-kind w) 'weighted))]
    [else #f]))

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

(define (regexp-full-match? pattern s)
  (define m (regexp-match pattern s))
  (and m (pair? m) (equal? (car m) s)))

(define (watcher-score watchers chunk)
  (for/fold ([ok? #t] [score 0.0])
            ([w (in-list watchers)])
    (cond
      [(ranked? w)
       (values ok?
               (log-score-add score
                              (if (monitor-match? (ranked-expr w) chunk)
                                  (ranked-score w)
                                  0.0)))]
      [(banned? w)
       (if (monitor-match? (banned-expr w) chunk)
           (values #f neg-inf)
           (values ok? score))]
      [(and (watch? w) (eq? (watch-kind w) 'weighted))
       (values ok?
               (for/fold ([acc score])
                         ([rule (in-list (weighted-observer-rules (watch-data w)))])
                 (if (monitor-match? (weighted-rule-expr rule) chunk)
                     (log-score-add acc (weighted-rule-weight rule))
                     acc)))]
      [(watch? w) (values ok? score)])))

(define (monitor-match? expr chunk)
  (cond
    [(string? expr) (string-contains? chunk expr)]
    [(guide? expr)
     (match (guide-kind expr)
       ['lit (string-contains? chunk (guide-data expr))]
       ['rx (regexp-match? (guide-data expr) chunk)]
       [else (raise-argument-error 'rank "lit, rx, or string" expr)])]
    [else (raise-argument-error 'rank "lit, rx, or string" expr)]))

(define (finite-candidates g)
  (define gg (ensure-guide 'finite-candidates g))
  (match (guide-kind gg)
    ['pure (list (list "" (guide-data gg) 0.0))]
    ['lit (list (list (guide-data gg) (void) 0.0))]
    ['ranked-guide
     (match-define (list score expr) (guide-data gg))
     (for/list ([c (in-list (finite-candidates expr))])
       (match-define (list s value base-score) c)
       (list s value (log-score-add score base-score)))]
    ['select
     (define choices (map finite-candidates (guide-data gg)))
     (and (andmap values choices) (apply append choices))]
    ['seq
     (for/fold ([acc (list (list "" (void) 0.0))])
               ([item (in-list (guide-data gg))])
       #:break (not acc)
       (define nexts (finite-candidates item))
       (and nexts
            (for*/list ([left (in-list acc)]
                        [right (in-list nexts)])
              (match-define (list ls _lv lscore) left)
              (match-define (list rs rv rscore) right)
              (list (string-append ls rs) rv (log-score-add lscore rscore)))))]
    ['bind
     (match-define (cons first cont) (guide-data gg))
     (define firsts (finite-candidates first))
     (and firsts
          (for*/list ([c (in-list firsts)]
                      [next (in-list
                             (or (finite-candidates (cont (second c))) '()))])
            (match-define (list s value score) c)
            (match-define (list ns nv nscore) next)
            (list (string-append s ns) nv (log-score-add score nscore))))]
    ['repeat
     (match-define (list min-count max-count item) (guide-data gg))
     (define item-candidates (finite-candidates item))
     (and item-candidates
          (letrec ([combine
                    (lambda (n)
                      (if (zero? n)
                          (list (list "" '() 0.0))
                          (for*/list ([head (in-list item-candidates)]
                                      [tail (in-list (combine (sub1 n)))])
                            (match-define (list hs hv hscore) head)
                            (match-define (list ts tv tscore) tail)
                            (list (string-append hs ts)
                                  (cons hv tv)
                                  (log-score-add hscore tscore)))))])
            (append-map combine (range min-count (add1 max-count)))))]
    [else #f]))
