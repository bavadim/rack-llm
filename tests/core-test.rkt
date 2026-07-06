#lang racket/base

(require racket/list
         racket/port
         racket/runtime-path
         racket/stream
         racket/string
         (except-in rackunit check)
         rack-llm
         rack-llm/llama-cpp)

(define (vec . xs) (list->vector xs))
(define (seeded-rng seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng])
    (random-seed seed))
  rng)
(define-runtime-path api-doc "../docs/api.md")
(define-runtime-path main-source "../main.rkt")
(define-runtime-path repo-root "..")
(define-runtime-path examples-dir "../examples")

(define (module-export-names module-path)
  (dynamic-require module-path #f)
  (define-values (value-exports syntax-exports)
    (module->exports module-path))
  (sort
   (append
    (for/list ([phase-group (in-list value-exports)]
               #:when (equal? (first phase-group) 0)
               [binding (in-list (rest phase-group))])
      (first binding))
    (for/list ([phase-group (in-list syntax-exports)]
               #:when (equal? (first phase-group) 0)
               [binding (in-list (rest phase-group))])
      (first binding)))
   symbol<?))

(define removed-api
  '(need must accept-score cap calc emit gen))

(define public-api-allowlist
  '(ban
    banned?
    bind
    check
    check-result
    check-result-failures
    check-result-guide-score
    check-result-hard-ok?
    check-result-matched-watchers
    check-result-metrics
    check-result-ok?
    check-result-trace
    check-result-value
    check-result?
    dead?
    detokenize
    done?
    fast-forward-state
    finite-candidates
    found?
    generate
    generate-stream
    generation-result
    generation-result-attempts
    generation-result-generated-tokens
    generation-result-guide-score
    generation-result-hard-ok?
    generation-result-latency-ms
    generation-result-lm-logprob
    generation-result-lm-score
    generation-result-low-score?
    generation-result-metrics
    generation-result-ok?
    generation-result-reason
    generation-result-status
    generation-result-steps
    generation-result-text
    generation-result-total-score
    generation-result-trace
    generation-result-value
    generation-result?
    guide-finish
    guide-init
    guide-step
    guide?
    hard-failure?
    lit
    log-score-add
    log-score-dead?
    log-score>?
    log-softmax
    make-mock-provider
    make-provider
    min-guide-score
    min-total-score
    not-found?
    provider-detokenize
    provider-metadata
    provider-mode
    provider-next-logits
    provider-tokenize
    provider-vocab
    provider?
    pure
    rank
    ranked?
    repeat
    rt-state
    rt-state-guide
    rt-state-potential
    rt-state-score
    rt-state-status
    rt-state-text
    rt-state-trace
    rt-state-value
    rt-state?
    rx
    sample-id
    select
    seq
    sequence-logprob
    state-potential
    state-score
    state-trace
    state-value
    struct:check-result
    struct:generation-result
    struct:rt-state
    text
    tokenize
    watch?
    weight))

(define (example-paths)
  (sort (filter (lambda (path)
                  (regexp-match? #rx"[.]rkt$" (path->string path)))
                (directory-list examples-dir #:build? #t))
        path<?))

(module+ test
  (test-case "closed guides accept exactly their language"
    (define g (seq "Answer: " (select "yes" "no")))
    (check-true (check-result-ok? (check g "Answer: yes")))
    (check-true (check-result-ok? (check g "Answer: no")))
    (check-false (check-result-ok? (check g "Answer: maybe"))))

  (test-case "prefix runtime distinguishes live, done, and dead"
    (define s0 (guide-init (seq "A" "B")))
    (define s1 (guide-step s0 "A"))
    (define s2 (guide-step s1 "B"))
    (define sx (guide-step s1 "C"))
    (check-false (dead? s1))
    (check-false (done? s1))
    (check-true (done? s2))
    (check-true (dead? sx))
    (check-true (dead? (guide-finish s1))))

  (test-case "closed runtime covers lit rx seq select repeat"
    (check-true (done? (guide-step (guide-init (lit "A")) "A")))
    (check-true (dead? (guide-step (guide-init (lit "A")) "B")))

    (define rx0 (guide-init (rx #px"[0-9]+")))
    (check-true (done? (guide-step rx0 "3")))
    (check-true (dead? (guide-step (guide-step rx0 "3") "a")))

    (check-false (dead? (guide-step (guide-init (seq "A" "B")) "A")))
    (check-true (done? (guide-step (guide-step (guide-init (seq "A" "B")) "A") "B")))

    (check-true (done? (guide-step (guide-init (select "yes" "no")) "yes")))
    (check-true (dead? (guide-step (guide-init (select "yes" "no")) "maybe")))

    (define r0 (guide-init (repeat 1 3 "a")))
    (define r1 (guide-step r0 "a"))
    (define r2 (guide-step r1 "a"))
    (define r3 (guide-step r2 "a"))
    (define r4 (guide-step r3 "a"))
    (check-true (done? r1))
    (check-true (done? r2))
    (check-true (done? r3))
    (check-true (dead? r4)))

  (test-case "finite-candidates enumerates finite guides only"
    (check-equal? (length (finite-candidates (select "yes" "no"))) 2)
    (check-equal? (third (car (finite-candidates (select (rank 2 "yes") "no"))))
                  2.0)
    (check-false (finite-candidates (text #:max-tokens 2))))

  (test-case "fast-forward literal advances without sampling choice"
    (define calls 0)
    (define p
      (make-provider
       #:vocab '("A" "B")
       #:next-logits (lambda (_prompt _prefix)
                       (set! calls (add1 calls))
                       (vec 0.0 0.0))))
    (define state (guide-init (lit "AB")))
    (define-values (next-state next-prefix lm-logprob scoring-calls)
      (fast-forward-state state p "" "" #:score? #f))
    (check-true (done? next-state))
    (check-equal? next-prefix "AB")
    (check-equal? lm-logprob 0.0)
    (check-equal? scoring-calls 0)
    (check-equal? calls 0)
    (define-values (_scored-state _scored-prefix scored-logprob scored-calls)
      (fast-forward-state state p "" "" #:score? #t))
    (check-equal? scored-calls 2)
    (check-true (< scored-logprob 0.0))
    (check-equal? calls 2))

  (test-case "rx runtime agrees with check on complete strings"
    (define g (rx #px"[0-9]+"))
    (for ([s (in-list '("3" "42" "x" "3x"))])
      (define state
        (for/fold ([state (guide-init g)])
                  ([token (in-list (map string (string->list s)))])
          (guide-step state token)))
      (check-equal? (done? state)
                    (check-result-ok? (check g s)))))

  (test-case "text runtime is open-world within its budget"
    (define state
      (for/fold ([state (guide-init (text #:max-tokens 4))])
                ([token (in-list '("a" "b" "c"))])
        (guide-step state token)))
    (check-false (done? state))
    (check-equal? (state-value state) #f)
    (check-false (dead? state)))

  (test-case "text runtime completes at its own budget"
    (define state
      (for/fold ([state (guide-init (text #:max-tokens 3))])
                ([token (in-list '("a" "b" "c"))])
        (guide-step state token)))
    (check-true (done? state))
    (check-equal? (state-value state) "abc"))

  (test-case "text rank watchers add positive and negative score"
    (define positive
      (guide-step (guide-init (text (rank 3 "patent"))) "patent"))
    (define negative
      (guide-step (guide-init (text (rank -5 "TODO"))) "TODO"))
    (check-equal? (state-score positive) 3.0)
    (check-equal? (state-score negative) -5.0)
    (check-match (state-trace positive) (list (list 'rank 3 "patent"))))

  (test-case "text ban kills matching prefixes but watcher misses stay live"
    (define banned-state
      (guide-step (guide-init (text (ban "secret"))) "secret"))
    (define missed-rank
      (guide-step (guide-init (text (rank 3 "patent"))) "ordinary"))
    (check-true (dead? banned-state))
    (check-false (dead? missed-rank))
    (check-equal? (state-score missed-rank) 0.0))

  (test-case "ban supports string lit and rx as hard vetoes"
    (check-false (check-result-ok? (check (text (ban "TODO")) "has TODO")))
    (check-false (check-result-ok? (check (text (ban (lit "TODO"))) "has TODO")))
    (check-false (check-result-ok? (check (text (ban (rx #px"TODO|secret"))) "secret")))
    (check-true (check-result-ok? (check (text (ban "TODO")) "clean"))))

  (test-case "check result exposes hard status, trace, failures, and matched watchers"
    (define ranked-result (check (text (rank 2 "yes")) "yes"))
    (check-true (check-result-ok? ranked-result))
    (check-true (check-result-hard-ok? ranked-result))
    (check-equal? (check-result-guide-score ranked-result) 2.0)
    (check-equal? (check-result-failures ranked-result) '())
    (check-match (check-result-trace ranked-result)
                 (list (list 'rank 2 "yes") (list 'final-value "yes")))
    (check-match (check-result-matched-watchers ranked-result)
                 (list (list 'rank 2 "yes")))
    (check-true (real? (hash-ref (check-result-metrics ranked-result) 'rule-time-ms)))

    (define banned-result (check (text (ban "secret")) "secret"))
    (check-false (check-result-ok? banned-result))
    (check-false (check-result-hard-ok? banned-result))
    (check-match (check-result-failures banned-result) (list (list 'ban -inf.0 "secret"))))

  (test-case "ban trace records hard failure"
    (define state
      (guide-step (guide-init (text (ban (rx #px"TODO|secret")))) "TODO"))
    (check-true (dead? state))
    (check-match (state-trace state) (list (list 'ban -inf.0 _))))

  (test-case "core log-score helpers preserve hard rejection"
    (check-true (log-score-dead? -inf.0))
    (check-equal? (log-score-add -inf.0 2.0) -inf.0)
    (check-equal? (log-score-add 1.5 2.0) 3.5)
    (check-true (log-score>? 1.0 0.0)))

  (test-case "rank and ban are delayed annotations"
    (check-true (ranked? (rank 2 "yes")))
    (check-false (guide? (rank 2 "yes")))
    (check-true (banned? (ban "no")))
    (check-exn #rx"rank: contract violation|rank: expected"
               (lambda () (rank 'high "yes"))))

  (test-case "contextual rank elaborates in closed and text contexts"
    (check-false (guide? (rank 2 "yes")))
    (check-true (check-result-ok? (check (select (rank 2 "yes") "no") "yes")))
    (check-true (check-result-ok? (check (select (rank 2 "yes") "no") "no")))
    (check-false (check-result-ok? (check (select (rank 2 "yes") "no") "maybe")))
    (check-equal? (check-result-guide-score
                   (check (text (rank 2 "yes")) "well yes"))
                  2.0)
    (check-true (check-result-ok? (check (text (rank 2 "yes")) "anything else")))
    (check-exn #rx"select"
               (lambda () (select (ban "secret")))))

  (test-case "rank is soft score over a closed choice"
    (define p
      (make-mock-provider
       #:vocab '("approve" "reject")
       #:default-logits (vec 0.0 1.0)))
    (define result
      (generate p "" (select (rank 3 "approve") "reject") #:beta 2.0))
    (check-equal? (generation-result-text result) "approve")
    (check-equal? (generation-result-guide-score result) 3.0)
    (check-= (generation-result-total-score result)
             (+ (generation-result-lm-logprob result) (* 2.0 3.0))
             1e-10))

  (test-case "beta zero disables finite soft score but preserves hard support"
    (define p
      (make-mock-provider
       #:vocab '("approve" "reject")
       #:default-logits (vec 0.0 1.0)))
    (define result
      (generate p "" (select (rank 3 "approve") "reject") #:beta 0.0))
    (check-equal? (generation-result-text result) "reject")
    (check-equal? (generation-result-status result) 'found)
    (check-= (generation-result-total-score result)
             (generation-result-lm-logprob result)
             1e-10))

  (test-case "ranked text can change generation when beta is positive"
    (define p
      (make-mock-provider
       #:vocab '("x" "patent")
       #:default-logits (vec 0.0 0.0)))
    (check-equal? (generation-result-text
                   (generate p "" (text (rank 3 "patent"))
                             #:beta 0.0
                             #:seed 3
                             #:max-tokens 1))
                  "x")
    (check-equal? (generation-result-text
                   (generate p "" (text (rank 3 "patent"))
                             #:beta 1.0
                             #:seed 3
                             #:max-tokens 1))
                  "patent"))

  (test-case "log-softmax converts logits to log probabilities"
    (define logprobs (log-softmax (vec 0.0 0.0)))
    (check-= (vector-ref logprobs 0) (- (log 2.0)) 1e-10)
    (check-= (vector-ref logprobs 1) (- (log 2.0)) 1e-10))

  (test-case "sequence-logprob sums token log probabilities"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)
       #:prefix-logits (hash "a" (vec -10.0 0.0))))
    (check-= (sequence-logprob p "" "ab")
             (+ (- (log 2.0))
                (- (log (+ 1.0 (exp -10.0)))))
             1e-10))

  (test-case "provider can delegate tokenization and detokenization"
    (define p
      (make-provider
       #:vocab '("<A>" "<B>")
       #:next-logits (lambda (_prompt _prefix) (vec 0.0 0.0))
       #:tokenize (lambda (text)
                    (cond
                      [(string=? text "AB") '(0 1)]
                      [(string=? text "A") '(0)]
                      [else '()]))
       #:detokenize (lambda (ids)
                      (cond
                        [(equal? ids '(0 1)) "AB"]
                        [(equal? ids '(0)) "A"]
                        [else ""]))))
    (check-equal? (tokenize p "AB") '(0 1))
    (check-equal? (detokenize p '(0 1)) "AB")
    (check-= (sequence-logprob p "" "AB")
             (* 2 (- (log 2.0)))
             1e-10))

  (test-case "sample-id is reproducible with the same seed"
    (define logits (vec 0.0 1.0 2.0))
    (check-equal? (sample-id logits (seeded-rng 123) 1.0)
                  (sample-id logits (seeded-rng 123) 1.0)))

  (test-case "ban is a hard veto in open text"
    (define p
      (make-mock-provider
       #:vocab '("TODO" "ok")
       #:default-logits (vec 10.0 0.0)))
    (define result
      (generate p "" (text #:max-tokens 8 (ban "TODO")) #:max-tokens 1))
    (check-equal? (generation-result-text result) "ok")
    (check-true (generation-result-ok? result)))

  (test-case "ban hard veto is independent of beta"
    (define p
      (make-mock-provider
       #:vocab '("TODO" "ok")
       #:default-logits (vec 10.0 0.0)))
    (for ([beta (in-list '(0.0 100.0))])
      (define result
        (generate p "" (text #:max-tokens 8 (ban "TODO")) #:beta beta #:max-tokens 1))
      (check-equal? (generation-result-text result) "ok")
      (check-equal? (generation-result-status result) 'found)))

  (test-case "generate sampling is reproducible with seed and records metrics"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define left (generate p "" (text #:max-tokens 2) #:seed 99 #:max-tokens 2))
    (define right (generate p "" (text #:max-tokens 2) #:seed 99 #:max-tokens 2))
    (check-equal? (generation-result-text left) (generation-result-text right))
    (check-equal? (hash-ref (generation-result-metrics left) 'steps)
                  (generation-result-steps left))
    (check-equal? (hash-ref (generation-result-metrics left) 'generated-tokens)
                  (generation-result-generated-tokens left))
    (check-true (real? (generation-result-latency-ms left))))

  (test-case "open text generation can continue for multiple tokens"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec -10.0 10.0)
       #:prefix-logits (hash "" (vec 10.0 -10.0)
                             "a" (vec -10.0 10.0))))
    (define result
      (generate p "" (text #:max-tokens 8)
                #:seed 7
                #:max-tokens 2))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (generation-result-text result) "ab")
    (check-equal? (generation-result-generated-tokens result) 2))

  (test-case "generate-stream yields lazy candidates"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define candidates
      (stream->list
       (stream-take
        (generate-stream p "" (text #:max-tokens 1) #:seed 0 #:max-tokens 1)
        3)))
    (check-equal? (length candidates) 3)
    (for ([candidate (in-list candidates)])
      (check-true (generation-result? candidate))))

  (test-case "generate keep-best chooses max total score"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define result
      (generate p "" (text #:max-tokens 1 (rank 5 "b"))
                #:seed 0
                #:samples 2
                #:keep-best? #t
                #:max-tokens 1))
    (check-equal? (generation-result-text result) "b")
    (check-equal? (generation-result-attempts result) 2))

  (test-case "generate samples can return duplicates with unique none"
    (define p
      (make-mock-provider
       #:vocab '("a")
       #:default-logits (vec 0.0)))
    (define results
      (generate p "" (text #:max-tokens 1)
                #:samples 2
                #:unique 'none
                #:max-tokens 1))
    (check-equal? (map generation-result-text results) '("a" "a")))

  (test-case "generate-stream unique cache skips recent duplicate text"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define texts
      (map generation-result-text
           (stream->list
            (stream-take
             (generate-stream p "" (text #:max-tokens 1)
                              #:seed 0
                              #:unique '(cache 2)
                              #:max-tokens 1)
             2))))
    (check-equal? texts '("a" "b")))

  (test-case "return policy can abstain on low guide score"
    (define p
      (make-mock-provider
       #:vocab '("ordinary")
       #:default-logits (vec 0.0)))
    (define without-policy
      (generate p "" (text (rank 2 "patent"))
                #:seed 1
                #:max-tokens 1))
    (define with-policy
      (generate p "" (text (rank 2 "patent"))
                #:seed 1
                #:max-tokens 1
                #:return-policy (min-guide-score 1.0)))
    (check-equal? (generation-result-status without-policy) 'found)
    (check-equal? (generation-result-guide-score without-policy) 0.0)
    (check-equal? (generation-result-status with-policy) 'not-found-low-score)
    (check-true (generation-result-low-score? with-policy))
    (check-true (string-contains? (generation-result-reason with-policy) "threshold")))

  (test-case "hard failure has priority over low-score policy"
    (define p
      (make-mock-provider
       #:vocab '("no")
       #:default-logits (vec 0.0)))
    (define result
      (generate p "" "yes" #:return-policy (min-guide-score 1.0)))
    (check-equal? (generation-result-status result) 'not-found-hard))

  (test-case "best-of applies policy to best candidate"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define found
      (generate p "" (text #:max-tokens 1 (rank 5 "b"))
                #:seed 0
                #:samples 2
                #:keep-best? #t
                #:return-policy (min-guide-score 4.0)
                #:max-tokens 1))
    (define rejected
      (generate p "" (text #:max-tokens 1 (rank 5 "b"))
                #:seed 0
                #:samples 2
                #:keep-best? #t
                #:return-policy (min-guide-score 6.0)
                #:max-tokens 1))
    (check-equal? (generation-result-status found) 'found)
    (check-equal? (generation-result-status rejected) 'not-found-low-score))

  (test-case "min-total-score uses beta-scaled guide score"
    (define p
      (make-mock-provider
       #:vocab '("patent")
       #:default-logits (vec 0.0)))
    (define found
      (generate p "" (text #:max-tokens 8 (rank 2 "patent"))
                #:beta 0.5
                #:max-tokens 1
                #:return-policy (min-total-score 0.5)))
    (define rejected
      (generate p "" (text #:max-tokens 8 (rank 2 "patent"))
                #:beta 0.5
                #:max-tokens 1
                #:return-policy (min-total-score 1.5)))
    (check-= (generation-result-total-score found) 1.0 1e-10)
    (check-equal? (generation-result-status found) 'found)
    (check-equal? (generation-result-status rejected) 'not-found-low-score))

  (test-case "weight rejects empty calibration data"
    (check-exn #rx"weight"
               (lambda ()
                 (weight #:data '() (rank 1 "positive")))))

  (test-case "weighted observer scores oriented watcher matches"
    (define learned
      (weight #:data '("patent granted"
                       "patent claim"
                       "TODO unknown"
                       "unknown null")
              (rank 1 "patent")
              (rank -1 "unknown")))
    (define positive (check (text learned) "new patent"))
    (define negative (check (text learned) "unknown value"))
    (check-true (> (check-result-guide-score positive) 0.0))
    (check-true (< (check-result-guide-score negative) 0.0))
    (check-match (check-result-trace positive)
                 (list (list 'weight _ "patent" _ _)
                       (list 'final-value "new patent"))))

  (test-case "weighted observer can affect generation"
    (define learned
      (weight #:data '("patent granted"
                       "patent claim"
                       "TODO unknown"
                       "unknown null")
              (rank 1 "patent")
              (rank -1 "unknown")))
    (define p
      (make-mock-provider
       #:vocab '("x" "patent")
       #:default-logits (vec 0.0 0.0)))
    (define result
      (generate p "" (text learned) #:seed 3 #:beta 2.0 #:max-tokens 1))
    (check-equal? (generation-result-text result) "patent")
    (check-true (> (generation-result-guide-score result) 0.0)))

  (test-case "hard-dead tokens are never sampled"
    (define p
      (make-mock-provider
       #:vocab '("TODO" "ok")
       #:default-logits (vec 100.0 0.0)))
    (for ([seed (in-range 10)])
      (define result
        (generate p "" (text #:max-tokens 8 (ban "TODO"))
                  #:seed seed
                  #:temperature 10.0
                  #:max-tokens 1))
      (check-equal? (generation-result-text result) "ok")
      (check-true (>= (hash-ref (generation-result-metrics result) 'dead-prefixes) 1))
      (check-equal? (hash-ref (generation-result-metrics result) 'provider-mode) 'mock)
      (check-true (>= (hash-ref (generation-result-metrics result) 'llm-calls) 1))
      (check-true (real? (hash-ref (generation-result-metrics result) 'rule-time-ms)))
      (check-true (real? (hash-ref (generation-result-metrics result) 'llm-time-ms)))))

  (test-case "deadline budget returns controlled error-budget result"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 0.0)))
    (define result
      (generate p "" (text #:max-tokens 4)
                #:deadline-ms 0
                #:max-tokens 1))
    (check-equal? (generation-result-status result) 'error-budget)
    (check-true (not-found? result))
    (check-false (generation-result-ok? result))
    (check-true (string? (generation-result-reason result))))

  (test-case "forced banned provider returns not found"
    (define p
      (make-mock-provider
       #:vocab '("TODO")
       #:default-logits (vec 0.0)))
    (define result
      (generate p "" (text #:max-tokens 8 (ban "TODO")) #:max-tokens 1))
    (check-equal? (generation-result-status result) 'not-found-hard))

  (test-case "generation result statuses have derived predicates"
    (define (result status)
      (generation-result status "reason" "" #f 0.0 0.0 0.0 #f #f 0 1 0 0.0 '() (hash)))
    (for ([status (in-list '(found
	                             not-found-hard
	                             not-found-budget
	                             not-found-low-score
	                             error-budget
	                             error-approx-provider
	                             internal-invalid))])
      (define r (result status))
      (check-equal? (found? r) (eq? status 'found))
      (check-equal? (generation-result-ok? r) (eq? status 'found))
      (check-equal? (not-found? r) (not (eq? status 'found))))
    (check-true (hard-failure? (result 'not-found-hard)))
    (check-false (hard-failure? (result 'not-found-budget))))

  (test-case "impossible finite guide reports not-found-hard"
    (define p
      (make-mock-provider
       #:vocab '("no")
       #:default-logits (vec 0.0)))
    (define result (generate p "" "yes"))
    (check-equal? (generation-result-status result) 'not-found-hard)
    (check-false (generation-result-ok? result))
    (check-true (string? (generation-result-reason result))))

  (test-case "provider contract validates vocab and exact full vectors"
    (check-exn #rx"make-provider"
               (lambda ()
                 (make-provider #:vocab '("yes" 1)
                                #:next-logits (lambda (_prompt _prefix) '#(0.0)))))
    (define bad
      (make-provider #:vocab '("yes")
                     #:next-logits (lambda (_prompt _prefix) '#())
                     #:mode 'exact-full-vocab))
    (check-exn #rx"next-logits"
               (lambda () (generate bad "" "yes"))))

  (test-case "mock provider is deterministic by prefix"
    (define p
      (make-mock-provider
       #:vocab '("a" "b")
       #:default-logits (vec 0.0 -1.0)
       #:prefix-logits (hash "a" (vec -2.0 3.0))))
    (check-equal? (provider-mode p) 'mock)
    (check-equal? ((provider-next-logits p) "" "") '#(0.0 -1.0))
    (check-equal? ((provider-next-logits p) "" "a") '#(-2.0 3.0)))

  (test-case "top-k approximate provider exposes mode and can fail exactly"
    (define p
      (make-provider
       #:vocab '("yes")
       #:mode 'top-k-approx
       #:next-logits (lambda (_prompt _prefix) (hash))))
    (check-equal? (provider-mode p) 'top-k-approx)
    (define result (generate p "" "yes"))
    (check-equal? (generation-result-status result) 'error-approx-provider)
    (check-true (string? (generation-result-reason result))))

  (test-case "open text without threshold reports found"
    (define p
      (make-mock-provider
       #:vocab '("ok")
       #:default-logits (vec 0.0)))
    (define result (generate p "" (text #:max-tokens 8) #:max-tokens 1))
    (check-equal? (generation-result-status result) 'found)
    (check-true (generation-result-ok? result)))

  (test-case "generate can complete a closed sequence through main API"
    (define p
      (make-mock-provider
       #:vocab '("A" "B")
       #:default-logits (vec 0.0 0.0)))
    (define result (generate p "" (seq "A" "B")))
    (check-equal? (generation-result-text result) "AB")
    (check-equal? (generation-result-status result) 'found)
    (check-true (check-result-ok? (check (seq "A" "B")
                                         (generation-result-text result)))))

  (test-case "found generation results pass check with matching guide score"
    (define p
      (make-mock-provider
       #:vocab '("patent" "x")
       #:default-logits (vec 0.0 0.0)))
    (define g (text (rank 3 "patent")))
    (define result (generate p "" g #:beta 1.0 #:max-tokens 1))
    (define checked (check g (generation-result-text result)))
    (check-equal? (generation-result-status result) 'found)
    (check-true (check-result-ok? checked))
    (check-equal? (generation-result-guide-score result)
                  (check-result-guide-score checked)))

  (test-case "bind passes generated values to ordinary Racket code"
    (define result
      (check (bind (rx #px"[0-9]")
                   (lambda (n)
                     (lit (number->string (+ 1 (string->number n))))))
             "34"))
    (check-true (check-result-ok? result)))

  (test-case "pure and bind compose values and strings"
    (define pure-result (check (pure 42) ""))
    (check-true (check-result-ok? pure-result))
    (check-equal? (check-result-value pure-result) 42)

    (define bind-result
      (check (bind (rx #px"[0-9]")
                   (lambda (n)
                     (seq " sum="
                          (number->string (+ 1 (string->number n))))))
             "2 sum=3"))
    (check-true (check-result-ok? bind-result)))

  (test-case "bind finite candidates work during generation"
    (define p
      (make-mock-provider
       #:vocab '("2" " sum=3")
       #:default-logits (vec 0.0 0.0)))
    (define g
      (bind (pure 2)
            (lambda (n)
              (seq "2" (format " sum=~a" (add1 n))))))
    (define result (generate p "" g))
    (check-equal? (generation-result-text result) "2 sum=3")
    (check-equal? (generation-result-status result) 'found))

  (test-case "bind can build dynamic regex guides"
    (define g
      (bind (rx #px"[A-Z][0-9]")
            (lambda (id)
              (seq ":" (rx (regexp (regexp-quote id)))))))
    (check-true (check-result-ok? (check g "A7:A7")))
    (check-false (check-result-ok? (check g "A7:B8"))))

  (test-case "bounded repetition stays finite"
    (define g (repeat 1 3 "a"))
    (check-true (check-result-ok? (check g "a")))
    (check-true (check-result-ok? (check g "aaa")))
    (check-false (check-result-ok? (check g "")))
    (check-false (check-result-ok? (check g "aaaa"))))

  (test-case "llama.cpp bridge decodes full logits arrays"
    (check-equal? (decode-logits (hash 'logits '(-1.0 0.0 2.5)))
                  '#(-1.0 0.0 2.5)))

  (test-case "api document covers public rack-llm exports"
    (define doc (call-with-input-file api-doc port->string))
    (for ([name (in-list (module-export-names 'rack-llm))])
      (check-true
       (string-contains? doc (symbol->string name))
       (format "missing API documentation for export ~a" name))))

  (test-case "public rack-llm exports match v1 allowlist"
    (check-equal? (module-export-names 'rack-llm)
                  (sort public-api-allowlist symbol<?)))

  (test-case "removed legacy operators stay out of docs and exports"
    (define doc (call-with-input-file api-doc port->string))
    (define exports (module-export-names 'rack-llm))
    (for ([name (in-list removed-api)])
      (check-false (member name exports))
      (check-false
       (regexp-match? (regexp (format "`~a`" (regexp-quote (symbol->string name)))) doc))))

  (test-case "removed legacy operators cannot be imported"
    (for ([name (in-list removed-api)])
      (check-exn
       exn:fail:syntax?
       (lambda ()
         (eval `(require (only-in rack-llm ,name))
               (make-base-namespace))))))

  (test-case "examples import only the public rack-llm API"
    (for ([path (in-list (example-paths))])
      (define source (call-with-input-file path port->string))
      (check-true
       (regexp-match? #px"\\(require\\s+rack-llm\\s*\\)" source)
       (format "example must import rack-llm directly: ~a" path))
      (check-false
       (regexp-match? #px"\\(require[^\n)]*rack-llm/" source)
       (format "example must not import internal rack-llm modules: ~a" path))))

  (test-case "main module stays a thin public boundary"
    (define source (call-with-input-file main-source port->string))
    (check-false (regexp-match? #px"\\(define\\b" source))
    (check-true (regexp-match? #px"\\(provide\\b" source)))

  (test-case "legacy runtime directories are absent"
    (for ([name (in-list '("notebooks" "ifbench" "runners"))])
      (check-false (directory-exists? (build-path repo-root name))))))
