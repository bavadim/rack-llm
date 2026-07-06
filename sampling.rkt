#lang racket/base

(require racket/list
         racket/match
         racket/stream
         "core.rkt"
         "provider.rkt"
         "runtime.rkt")

(provide generate
         generate-stream
         finite-candidates
         fast-forward-state
         min-guide-score
         min-total-score
         log-softmax
         sequence-logprob
         sample-id)

(struct score-policy (kind threshold) #:transparent)
(struct token-selection
  (id token raw-logit lm-logprob adjustment dead-count next-state candidate-count)
  #:transparent)

(define deadline-poll-interval 1)
(define sampling-finite-candidate-limit 10000)

(define (min-guide-score threshold)
  (make-score-policy 'min-guide-score threshold))

(define (min-total-score threshold)
  (make-score-policy 'min-total-score threshold))

(define (make-score-policy kind threshold)
  (unless (real? threshold)
    (raise-argument-error kind "real?" threshold))
  (score-policy kind threshold))

(define (generate p prompt g
                  #:beta [beta 1.0]
                  #:lambda [lambda-weight 0.5]
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128]
                  #:samples [samples 1]
                  #:keep-best? [keep-best? #f]
                  #:unique [unique 'none]
                  #:candidate-policy [candidate-policy 'full-vocab]
                  #:return-policy [return-policy 'always])
  (unless (exact-positive-integer? samples)
    (raise-argument-error 'generate "positive exact integer?" samples))
  (define candidates
    (stream-take/list
     (generate-stream p prompt g
                      #:beta beta
                      #:lambda lambda-weight
                      #:temperature temperature
                      #:seed seed
                      #:deadline-ms deadline-ms
                      #:max-tokens max-tokens
                      #:unique unique
                      #:candidate-policy candidate-policy)
     samples))
  (define with-attempt-count
    (for/list ([candidate (in-list candidates)])
      (set-result-attempts candidate samples)))
  (cond
    [keep-best? (apply-return-policy (argmax generation-result-total-score with-attempt-count)
                                     return-policy)]
    [(= samples 1) (apply-return-policy (car with-attempt-count) return-policy)]
    [else (map (lambda (candidate) (apply-return-policy candidate return-policy))
               with-attempt-count)]))

(define (generate-stream p prompt g
                         #:beta [beta 1.0]
                         #:lambda [lambda-weight 0.5]
                         #:temperature [temperature 0.7]
                         #:seed [seed #f]
                         #:deadline-ms [deadline-ms #f]
                         #:max-tokens [max-tokens 128]
                         #:unique [unique 'none]
                         #:candidate-policy [candidate-policy 'full-vocab])
  (define guide (ensure-guide 'generate-stream g))
  (let loop ([attempt 0] [cache '()])
    (define result
      (generate-one p prompt guide
                    #:beta beta
                    #:lambda lambda-weight
                    #:temperature temperature
                    #:seed (attempt-seed seed attempt)
                    #:deadline-ms deadline-ms
                    #:max-tokens max-tokens
                    #:candidate-policy candidate-policy))
    (define duplicate? (cache-contains? unique cache (generation-result-text result)))
    (define next-cache (cache-add unique cache (generation-result-text result)))
    (if duplicate?
        (loop (add1 attempt) next-cache)
        (stream-cons result (loop (add1 attempt) next-cache)))))

(define (generate-one p prompt guide
                      #:beta beta
                      #:lambda lambda-weight
                      #:temperature temperature
                      #:seed seed
                      #:deadline-ms deadline-ms
                      #:max-tokens max-tokens
                      #:candidate-policy candidate-policy)
  (define started-ms (current-inexact-milliseconds))
  (define rng (make-rng seed))
  (cond
    [(not (sampling-supported? guide))
     (make-generation-result
      #:status 'unsupported-guide-for-sampling
      #:reason "guide has no production prefix-runtime for sampling"
      #:text ""
      #:value #f
      #:lm-logprob neg-inf
      #:guide-score neg-inf
      #:beta beta
      #:hard-ok? #f
      #:latency-ms (elapsed-ms started-ms)
      #:metrics (basic-metrics 0 0 started-ms
                               #:provider-mode (provider-mode p)
                               #:candidate-policy candidate-policy
                               #:unsupported-reason 'unsupported-guide-for-sampling))]
    [(eq? (guide-kind guide) 'select)
     (define finite (finite-candidates guide
                                       #:max-finite-candidates
                                       sampling-finite-candidate-limit))
     (if (list? finite)
         (best-finite p prompt finite beta started-ms)
         (make-generation-result
          #:status 'unsupported-guide-for-sampling
          #:reason "select has too many finite candidates for best-finite"
          #:text ""
          #:value #f
          #:lm-logprob neg-inf
          #:guide-score neg-inf
          #:beta beta
          #:hard-ok? #f
          #:latency-ms (elapsed-ms started-ms)
          #:metrics (basic-metrics 0 0 started-ms
                                   #:provider-mode (provider-mode p)
                                   #:candidate-policy candidate-policy
                                   #:unsupported-reason 'too-many-finite-candidates)))]
    [else
     (generate-text p prompt guide beta lambda-weight temperature rng deadline-ms
                    max-tokens started-ms (provider-vocab-vector p)
                    candidate-policy)]))

(define (stream-take/list s n)
  (let loop ([s s] [remaining n])
    (if (zero? remaining)
        '()
        (cons (stream-first s)
              (loop (stream-rest s) (sub1 remaining))))))

(define (attempt-seed seed attempt)
  (and seed (+ seed attempt)))

(define (set-result-attempts result attempts)
  (struct-copy generation-result result
               [attempts attempts]
               [metrics (hash-set (generation-result-metrics result) 'attempts attempts)]))

(define (cache-contains? unique cache text)
  (match unique
    ['none #f]
    [(list 'cache n) (member text cache)]
    ['exact (raise-arguments-error 'generate-stream
                                   "unique mode 'exact is reserved for future v1 work")]
    [else (raise-argument-error 'generate-stream "'none or '(cache N)" unique)]))

(define (cache-add unique cache text)
  (match unique
    ['none cache]
    [(list 'cache n)
     (unless (exact-positive-integer? n)
       (raise-argument-error 'generate-stream "positive cache size" n))
     (take (cons text cache) (min n (add1 (length cache))))]
    ['exact cache]
    [else cache]))

(define (apply-return-policy result policy)
  (cond
    [(not (found? result)) result]
    [(eq? policy 'always) result]
    [(eq? policy 'hard-only) result]
    [(score-policy? policy)
     (define observed
       (case (score-policy-kind policy)
         [(min-guide-score) (generation-result-guide-score result)]
         [(min-total-score) (generation-result-total-score result)]
         [else (raise-argument-error 'generate "known return policy" policy)]))
     (if (< observed (score-policy-threshold policy))
         (struct-copy generation-result result
                      [status 'not-found-low-score]
                      [reason (format "~a threshold ~a not met; observed ~a"
                                      (score-policy-kind policy)
                                      (score-policy-threshold policy)
                                      observed)]
                      [low-score? #t])
         result)]
    [else (raise-argument-error 'generate
                                "'always, 'hard-only, (min-guide-score n), or (min-total-score n)"
                                policy)]))

(define (make-rng seed)
  (define rng (make-pseudo-random-generator))
  (when seed
    (unless (exact-integer? seed)
      (raise-argument-error 'generate "exact integer seed" seed))
    (parameterize ([current-pseudo-random-generator rng])
      (random-seed seed)))
  rng)

(define (sampleable? score)
  (not (log-score-dead? score)))

(define (combined-score lm-logprob guide-score beta)
  (cond
    [(or (log-score-dead? lm-logprob) (log-score-dead? guide-score)) neg-inf]
    [else (log-score-add lm-logprob (* beta guide-score))]))

(define (transition-adjustment state token-id token last-score last-potential beta lambda-weight)
  (define next-state (guide-step-runtime state token-id token))
  (cond
    [(dead? next-state)
     (values next-state neg-inf #t)]
    [else
     (define guide-score (state-score next-state))
     (define delta-score (- guide-score last-score))
     (define potential (state-potential next-state))
     (define delta-potential (- potential last-potential))
     (values next-state
             (* beta (+ delta-score (* lambda-weight delta-potential)))
             #f)]))

(define (best-finite p prompt candidates beta started-ms)
  (define scored
    (for/list ([c (in-list candidates)]
               #:do [(match-define (list s value guide-score) c)
                     (define lm-score (sequence-logprob/false p prompt s))]
               #:when lm-score)
      (define token-count (length (tokenize p s)))
      (make-generation-result
       #:status 'found
       #:reason #f
       #:text s
       #:value value
       #:lm-logprob lm-score
       #:guide-score guide-score
       #:beta beta
       #:hard-ok? #t
       #:steps token-count
       #:generated-tokens token-count
       #:latency-ms (elapsed-ms started-ms)
       #:metrics (basic-metrics token-count
                                token-count
                                started-ms
                                #:provider-mode (provider-mode p)))))
  (if (null? scored)
      (make-generation-result
       #:status (if (eq? (provider-mode p) 'top-k-approx)
                    'error-approx-provider
                    'not-found-hard)
       #:reason (if (eq? (provider-mode p) 'top-k-approx)
                    "top-k provider did not return logits for any valid finite candidate"
                    "no finite candidate can be tokenized and scored by the provider")
       #:text ""
       #:value #f
       #:lm-logprob neg-inf
       #:guide-score neg-inf
       #:beta beta
       #:hard-ok? #f
       #:latency-ms (elapsed-ms started-ms)
       #:metrics (basic-metrics 0 0 started-ms
                                #:provider-mode (provider-mode p)))
      (argmax generation-result-total-score scored)))

(define (sequence-logprob/false p prompt s)
  (define ids
    (with-handlers ([exn:fail? (lambda (_exn) #f)])
      (tokenize p s)))
  (and ids (sequence-logprob/ids p prompt ids #f)))

(define (sequence-logprob p prompt s)
  (sequence-logprob/ids p prompt (tokenize p s) neg-inf))

(define (sequence-logprob/ids p prompt ids dead-value)
  (let loop ([ids ids] [prefix ""] [score 0.0])
    (cond
      [(null? ids) score]
      [else
       (define id (car ids))
       (define logits (provider-next-logit-vector p prompt prefix))
       (define logprobs (log-softmax logits))
       (define token-logprob (vector-ref logprobs id))
       (if (log-score-dead? token-logprob)
           dead-value
           (loop (cdr ids)
                 (string-append prefix (detokenize p (list id)))
                 (log-score-add score token-logprob)))])))

(define (fast-forward-state state provider prompt prefix
                            #:score? [score? #t]
                            #:allow-complete-lit? [allow-complete-lit? #t]
                            #:return-ids? [return-ids? #f])
  (define forced (runtime-forced-string state))
  (cond
    [(or (not forced) (string=? forced ""))
     (values state prefix 0.0 (if return-ids? '() 0))]
    [else
     (with-handlers ([exn:fail? (lambda (_exn)
                                  (values state prefix neg-inf (if return-ids? '() 0)))])
       (define ids (tokenize provider forced))
       (define-values (next-state next-prefix)
         (for/fold ([st state] [out prefix])
                   ([id (in-list ids)])
           (define token (provider-token-ref provider id))
           (values (guide-step-runtime st id token)
                   (string-append out token))))
       (if (and (done? next-state)
                (eq? (guide-kind (rt-state-guide state)) 'lit))
           (if allow-complete-lit?
               (let ([lm-logprob
                 (if score? (sequence-logprob provider prompt forced) 0.0)])
                 (values next-state next-prefix lm-logprob
                         (if return-ids? ids (if score? (length ids) 0))))
               (values state prefix 0.0 (if return-ids? '() 0)))
           (let ([lm-logprob
                  (if score? (sequence-logprob provider prompt forced) 0.0)])
             (values next-state next-prefix lm-logprob
                     (if return-ids? ids (if score? (length ids) 0))))))]))

(define (string-prefix-of? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (generate-text p prompt guide beta lambda-weight temperature rng deadline-ms
                       max-tokens started-ms vocab-vec candidate-policy)
  (define session? (provider-session-supported? p))
  (define session (and session? ((provider-start-session p) prompt)))
  (define (next-logits prefix)
    (if session?
        (let ([raw ((provider-next-logits/session p) session)])
          (case (provider-mode p)
            [(exact-full-vocab mock)
             (unless (and (vector? raw) (= (vector-length raw) (provider-vocab-size p)))
               (error 'provider-next-logits/session
                      "logits vector length must match vocabulary"))
             raw]
            [(top-k-approx) raw]
            [else raw]))
        (provider-next-logit-vector p prompt prefix)))
  (define (commit! id)
    (when session?
      ((provider-commit-token! p) session id)))
  (define (end-session!)
    (when session?
      ((provider-end-session! p) session)))
  (define (finish result)
    (end-session!)
    result)
  (let loop ([step 0]
             [prefix ""]
             [state (guide-init-runtime guide p)]
             [last-score 0.0]
             [last-potential 0.0]
             [lm-score 0.0]
             [llm-calls 0]
             [dead-prefixes 0]
             [candidate-total 0]
             [candidate-per-step '()]
             [runtime-step-calls 0]
             [allowed-token-count 0]
             [fast-forward-tokens 0]
             [rule-time-ms 0.0]
             [llm-time-ms 0.0]
             [sampling-time-ms 0.0])
    (cond
      [(deadline-expired? started-ms deadline-ms)
       (finish
        (budget-error-result state prefix lm-score beta step started-ms p llm-calls
                             dead-prefixes rule-time-ms llm-time-ms
                             "deadline exhausted"
                             #:candidate-policy candidate-policy
                             #:candidate-count-total candidate-total
                             #:candidate-count-per-step (reverse candidate-per-step)
                             #:runtime-step-calls runtime-step-calls
                             #:allowed-token-count allowed-token-count
                             #:fast-forward-tokens fast-forward-tokens
                             #:sampling-time-ms sampling-time-ms
                             #:provider-session? session?))]
      [(done? state)
       (finish
        (result-from-state state lm-score beta step started-ms p
                           llm-calls dead-prefixes rule-time-ms llm-time-ms
                           #:candidate-policy candidate-policy
                           #:candidate-count-total candidate-total
                           #:candidate-count-per-step (reverse candidate-per-step)
                           #:runtime-step-calls runtime-step-calls
                           #:allowed-token-count allowed-token-count
                           #:fast-forward-tokens fast-forward-tokens
                           #:sampling-time-ms sampling-time-ms
                           #:provider-session? session?))]
      [(>= step max-tokens)
       (finish
        (if (eq? (guide-kind (rt-state-guide state)) 'text)
            (make-generation-result
             #:status 'found
             #:reason #f
             #:text prefix
             #:value prefix
             #:lm-logprob lm-score
             #:guide-score (state-score state)
             #:beta beta
             #:hard-ok? #t
             #:steps step
             #:generated-tokens step
             #:latency-ms (elapsed-ms started-ms)
             #:trace (append (state-trace state) (list (list 'final-value prefix)))
             #:metrics (basic-metrics step step started-ms
                                      #:provider-mode (provider-mode p)
                                      #:llm-calls llm-calls
                                      #:dead-prefixes dead-prefixes
                                      #:rule-time-ms rule-time-ms
                                      #:llm-time-ms llm-time-ms
                                      #:vocab-size (provider-vocab-size p)
                                      #:candidate-policy candidate-policy
                                      #:candidate-count-total candidate-total
                                      #:candidate-count-per-step (reverse candidate-per-step)
                                      #:runtime-step-calls runtime-step-calls
                                      #:allowed-token-count allowed-token-count
                                      #:fast-forward-tokens fast-forward-tokens
                                      #:sampling-time-ms sampling-time-ms
                                      #:provider-session? session?))
            (make-generation-result
             #:status 'not-found-budget
             #:reason "token budget exhausted"
             #:text prefix
             #:value #f
             #:lm-logprob lm-score
             #:guide-score (state-score state)
             #:beta beta
             #:hard-ok? #f
             #:steps step
             #:generated-tokens step
             #:latency-ms (elapsed-ms started-ms)
             #:trace (state-trace state)
             #:metrics (basic-metrics step step started-ms
                                      #:provider-mode (provider-mode p)
                                      #:llm-calls llm-calls
                                      #:dead-prefixes dead-prefixes
                                      #:rule-time-ms rule-time-ms
                                      #:llm-time-ms llm-time-ms
                                      #:vocab-size (provider-vocab-size p)
                                      #:candidate-policy candidate-policy
                                      #:candidate-count-total candidate-total
                                      #:candidate-count-per-step (reverse candidate-per-step)
                                      #:runtime-step-calls runtime-step-calls
                                      #:allowed-token-count allowed-token-count
                                      #:fast-forward-tokens fast-forward-tokens
                                      #:sampling-time-ms sampling-time-ms
                                      #:provider-session? session?))))]
      [else
       (define-values (ff-state ff-prefix ff-lm ff-ids)
         (fast-forward-state state p prompt prefix
                             #:score? #f
                             #:allow-complete-lit? #f
                             #:return-ids? #t))
       (cond
         [(positive? (length ff-ids))
          (for ([id (in-list ff-ids)]) (commit! id))
          (loop (+ step (length ff-ids))
                ff-prefix
                ff-state
                (state-score ff-state)
                (state-potential ff-state)
                (log-score-add lm-score ff-lm)
                llm-calls
                dead-prefixes
                candidate-total
                candidate-per-step
                runtime-step-calls
                allowed-token-count
                (+ fast-forward-tokens (length ff-ids))
                rule-time-ms
                llm-time-ms
                sampling-time-ms)]
         [else
          (define llm-start (current-inexact-milliseconds))
          (define logits (next-logits prefix))
          (define next-llm-time-ms (+ llm-time-ms (- (current-inexact-milliseconds) llm-start)))
          (cond
            [(deadline-expired? started-ms deadline-ms)
             (finish
              (budget-error-result state prefix lm-score beta step started-ms p llm-calls
                                   dead-prefixes rule-time-ms next-llm-time-ms
                                   "deadline exhausted after provider logits"
                                   #:candidate-policy candidate-policy
                                   #:candidate-count-total candidate-total
                                   #:candidate-count-per-step (reverse candidate-per-step)
                                   #:runtime-step-calls runtime-step-calls
                                   #:allowed-token-count allowed-token-count
                                   #:fast-forward-tokens fast-forward-tokens
                                   #:sampling-time-ms sampling-time-ms
                                   #:provider-session? session?))]
            [else
          (define next-llm-calls (add1 llm-calls))
          (define sampling-start (current-inexact-milliseconds))
          (define selection
            (select-token state
                          logits
                          vocab-vec
                          p
                          candidate-policy
                          last-score
                          last-potential
                          beta
                          lambda-weight
                          temperature
                          rng
                          started-ms
                          deadline-ms))
          (define next-sampling-time-ms
            (+ sampling-time-ms (- (current-inexact-milliseconds) sampling-start)))
          (define considered
            (if (token-selection? selection)
                (token-selection-candidate-count selection)
                0))
          (define next-candidate-total (+ candidate-total considered))
          (define next-candidate-per-step (cons considered candidate-per-step))
          (define next-runtime-step-calls (+ runtime-step-calls considered))
          (define next-allowed-count
            (+ allowed-token-count
               (if (runtime-allowed-next-ids state)
                   (length (runtime-allowed-next-ids state))
                   0)))
          (cond
            [(eq? selection 'budget)
             (finish
              (budget-error-result state prefix lm-score beta step started-ms p
                                   next-llm-calls dead-prefixes rule-time-ms
                                   next-llm-time-ms
                                   "deadline exhausted during candidate sampling pass"
                                   #:candidate-policy candidate-policy
                                   #:candidate-count-total candidate-total
                                   #:candidate-count-per-step (reverse candidate-per-step)
                                   #:runtime-step-calls runtime-step-calls
                                   #:allowed-token-count allowed-token-count
                                   #:fast-forward-tokens fast-forward-tokens
                                   #:sampling-time-ms next-sampling-time-ms
                                   #:provider-session? session?))]
            [(not (token-selection-id selection))
             (finish
              (make-generation-result
               #:status (if (eq? (provider-mode p) 'top-k-approx)
                            'error-approx-provider
                            'not-found-hard)
               #:reason (if (eq? (provider-mode p) 'top-k-approx)
                            "top-k provider returned no viable token for the guide"
                            "no provider token keeps the guide valid")
               #:text prefix
               #:value #f
               #:lm-logprob lm-score
               #:guide-score neg-inf
               #:beta beta
               #:hard-ok? #f
               #:steps step
               #:generated-tokens step
               #:latency-ms (elapsed-ms started-ms)
               #:metrics (basic-metrics step step started-ms
                                        #:provider-mode (provider-mode p)
                                        #:llm-calls next-llm-calls
                                        #:dead-prefixes (+ dead-prefixes
                                                          (token-selection-dead-count selection))
                                        #:rule-time-ms rule-time-ms
                                        #:llm-time-ms next-llm-time-ms
                                        #:vocab-size (provider-vocab-size p)
                                        #:candidate-policy candidate-policy
                                        #:candidate-count-total next-candidate-total
                                        #:candidate-count-per-step (reverse next-candidate-per-step)
                                        #:runtime-step-calls next-runtime-step-calls
                                        #:allowed-token-count next-allowed-count
                                        #:fast-forward-tokens fast-forward-tokens
                                        #:sampling-time-ms next-sampling-time-ms
                                        #:provider-session? session?)))]
            [else
             (commit! (token-selection-id selection))
             (define next-state (token-selection-next-state selection))
             (define next-prefix (string-append prefix (token-selection-token selection)))
             (define next-lm-score
               (log-score-add lm-score (token-selection-lm-logprob selection)))
             (define next-dead-prefixes
               (+ dead-prefixes (token-selection-dead-count selection)))
             (if (done? next-state)
                 (finish
                  (result-from-state next-state next-lm-score beta (add1 step) started-ms p
                                    next-llm-calls next-dead-prefixes
                                    rule-time-ms next-llm-time-ms
                                    #:candidate-policy candidate-policy
                                    #:candidate-count-total next-candidate-total
                                    #:candidate-count-per-step (reverse next-candidate-per-step)
                                    #:runtime-step-calls next-runtime-step-calls
                                    #:allowed-token-count next-allowed-count
                                    #:fast-forward-tokens fast-forward-tokens
                                    #:sampling-time-ms next-sampling-time-ms
                                    #:provider-session? session?))
                 (loop (add1 step)
                       next-prefix
                       next-state
                       (state-score next-state)
                       (state-potential next-state)
                       next-lm-score
                       next-llm-calls
                       next-dead-prefixes
                       next-candidate-total
                       next-candidate-per-step
                       next-runtime-step-calls
                       next-allowed-count
                       fast-forward-tokens
                       rule-time-ms
                       next-llm-time-ms
                       next-sampling-time-ms))])])])])))

(define (select-token state logits vocab-vec provider candidate-policy
                      last-score last-potential beta lambda-weight temperature
                      rng started-ms deadline-ms)
  (unless (and (real? temperature) (> temperature 0))
    (raise-argument-error 'generate "positive real temperature" temperature))
  (define ids (candidate-ids state logits provider candidate-policy))
  (define-values (max-logit exp-sum)
    (for/fold ([max-logit -inf.0] [exp-sum 0.0])
              ([logit (in-vector logits)])
      (logsumexp-accumulate max-logit exp-sum logit)))
  (define-values (best-id best-token best-raw-logit best-adjustment best-score best-state dead-count budget?)
    (for/fold ([best-id #f]
               [best-token #f]
               [best-raw-logit -inf.0]
               [best-adjustment 0.0]
               [best-score -inf.0]
               [best-state #f]
               [dead-count 0]
               [budget? #f])
              ([id (in-list ids)])
      (cond
        [budget?
         (values best-id best-token best-raw-logit best-adjustment best-score
                 best-state dead-count budget?)]
        [(and (zero? (remainder id deadline-poll-interval))
              (deadline-expired? started-ms deadline-ms))
         (values best-id best-token best-raw-logit best-adjustment best-score
                 best-state dead-count #t)]
        [else
         (define noise (gumbel rng))
         (define logit (vector-ref logits id))
         (cond
           [(log-score-dead? logit)
            (values best-id best-token best-raw-logit best-adjustment best-score
                    best-state (add1 dead-count) #f)]
           [else
            (define token (vector-ref vocab-vec id))
            (define-values (next-state adjustment dead-transition?)
              (transition-adjustment state id token last-score last-potential beta lambda-weight))
            (define adjusted
              (if dead-transition? neg-inf (+ logit adjustment)))
            (cond
              [(not (sampleable? adjusted))
               (values best-id best-token best-raw-logit best-adjustment best-score
                       best-state (add1 dead-count) #f)]
              [else
               (define score (+ (/ adjusted temperature) noise))
               (if (or (not best-id) (> score best-score))
                   (values id token logit adjustment score next-state dead-count #f)
                   (values best-id best-token best-raw-logit best-adjustment best-score
                           best-state dead-count #f))])])])))
  (cond
    [budget? 'budget]
    [(not best-id)
     (token-selection #f #f -inf.0 -inf.0 0.0 dead-count #f (length ids))]
    [else
     (define log-z
       (if (log-score-dead? max-logit)
           +inf.0
           (+ max-logit (log exp-sum))))
     (token-selection best-id
                      best-token
                      best-raw-logit
                      (- best-raw-logit log-z)
                      best-adjustment
                      dead-count
                      best-state
                      (length ids))]))

(define (candidate-ids state logits provider policy)
  (define vocab-size (vector-length logits))
  (define (all) (range vocab-size))
  (match policy
    ['full-vocab (all)]
    ['allowed-only
     (or (runtime-allowed-next-ids state) (all))]
    [(list 'top-k+watch k)
     (unless (exact-positive-integer? k)
       (raise-argument-error 'generate "positive K in '(top-k+watch K)" k))
     (remove-duplicates
      (append (top-k-ids logits k)
              (runtime-watch-ids state provider)))]
    [else (raise-argument-error 'generate
                                "'full-vocab, 'allowed-only, or '(top-k+watch K)"
                                policy)]))

(define (top-k-ids logits k)
  (define pairs
    (sort
     (for/list ([logit (in-vector logits)] [id (in-naturals)])
       (cons id logit))
     >
     #:key cdr))
  (map car (take pairs (min k (length pairs)))))

(define (logsumexp-accumulate max-logit exp-sum logit)
  (cond
    [(log-score-dead? logit) (values max-logit exp-sum)]
    [(log-score-dead? max-logit) (values logit 1.0)]
    [(> logit max-logit)
     (values logit (+ (* exp-sum (exp (- max-logit logit))) 1.0))]
    [else
     (values max-logit (+ exp-sum (exp (- logit max-logit))))]))

(define (result-from-state state lm-score beta step started-ms p llm-calls dead-prefixes rule-time-ms llm-time-ms
                           #:candidate-policy [candidate-policy 'full-vocab]
                           #:candidate-count-total [candidate-count-total 0]
                           #:candidate-count-per-step [candidate-count-per-step '()]
                           #:runtime-step-calls [runtime-step-calls 0]
                           #:allowed-token-count [allowed-token-count 0]
                           #:fast-forward-tokens [fast-forward-tokens 0]
                           #:sampling-time-ms [sampling-time-ms 0.0]
                           #:provider-session? [provider-session? #f])
  (make-generation-result
   #:status 'found
   #:reason #f
   #:text (rt-state-text state)
   #:value (state-value state)
   #:lm-logprob lm-score
   #:guide-score (state-score state)
   #:beta beta
   #:hard-ok? #t
   #:steps step
   #:generated-tokens step
   #:latency-ms (elapsed-ms started-ms)
   #:metrics (basic-metrics step step started-ms
                            #:provider-mode (provider-mode p)
                            #:llm-calls llm-calls
                            #:dead-prefixes dead-prefixes
                            #:rule-time-ms rule-time-ms
                            #:llm-time-ms llm-time-ms
                            #:vocab-size (provider-vocab-size p)
                            #:candidate-policy candidate-policy
                            #:candidate-count-total candidate-count-total
                            #:candidate-count-per-step candidate-count-per-step
                            #:runtime-step-calls runtime-step-calls
                            #:allowed-token-count allowed-token-count
                            #:fast-forward-tokens fast-forward-tokens
                            #:sampling-time-ms sampling-time-ms
                            #:provider-session? provider-session?)
   #:trace (append (state-trace state) (list (list 'final-value (state-value state))))))

(define (result-from-check guide s lm-score failure-status failure-reason beta step started-ms p llm-calls dead-prefixes rule-time-ms llm-time-ms)
  (define checked (check guide s))
  (define guide-score (check-result-guide-score checked))
  (if (check-result-ok? checked)
      (make-generation-result
       #:status 'found
       #:reason #f
       #:text s
       #:value (check-result-value checked)
       #:lm-logprob lm-score
       #:guide-score guide-score
       #:beta beta
       #:hard-ok? #t
       #:steps step
       #:generated-tokens step
       #:latency-ms (elapsed-ms started-ms)
       #:metrics (basic-metrics step step started-ms
                                #:provider-mode (provider-mode p)
                                #:llm-calls llm-calls
                                #:dead-prefixes dead-prefixes
                                #:rule-time-ms rule-time-ms
                                #:llm-time-ms llm-time-ms))
      (make-generation-result
       #:status failure-status
       #:reason failure-reason
       #:text s
       #:value (check-result-value checked)
       #:lm-logprob lm-score
       #:guide-score guide-score
       #:beta beta
       #:hard-ok? #f
       #:steps step
       #:generated-tokens step
       #:latency-ms (elapsed-ms started-ms)
	       #:metrics (basic-metrics step step started-ms
	                                #:provider-mode (provider-mode p)
	                                #:llm-calls llm-calls
	                                #:dead-prefixes dead-prefixes
	                                #:rule-time-ms rule-time-ms
	                                #:llm-time-ms llm-time-ms))))

(define (budget-error-result state s lm-score beta step started-ms p llm-calls dead-prefixes rule-time-ms llm-time-ms reason
                             #:candidate-policy [candidate-policy 'full-vocab]
                             #:candidate-count-total [candidate-count-total 0]
                             #:candidate-count-per-step [candidate-count-per-step '()]
                             #:runtime-step-calls [runtime-step-calls 0]
                             #:allowed-token-count [allowed-token-count 0]
                             #:fast-forward-tokens [fast-forward-tokens 0]
                             #:sampling-time-ms [sampling-time-ms 0.0]
                             #:provider-session? [provider-session? #f])
  (make-generation-result
   #:status 'error-budget
   #:reason reason
   #:text s
   #:value #f
   #:lm-logprob lm-score
   #:guide-score (state-score state)
   #:beta beta
   #:hard-ok? #f
   #:steps step
   #:generated-tokens step
   #:latency-ms (elapsed-ms started-ms)
   #:trace (state-trace state)
   #:metrics (basic-metrics step step started-ms
                            #:provider-mode (provider-mode p)
                            #:llm-calls llm-calls
                            #:dead-prefixes dead-prefixes
                            #:rule-time-ms rule-time-ms
                            #:llm-time-ms llm-time-ms
                            #:vocab-size (provider-vocab-size p)
                            #:candidate-policy candidate-policy
                            #:candidate-count-total candidate-count-total
                            #:candidate-count-per-step candidate-count-per-step
                            #:runtime-step-calls runtime-step-calls
                            #:allowed-token-count allowed-token-count
                            #:fast-forward-tokens fast-forward-tokens
                            #:sampling-time-ms sampling-time-ms
                            #:provider-session? provider-session?)))

(define (deadline-expired? started-ms deadline-ms)
  (and deadline-ms
       (>= (elapsed-ms started-ms) deadline-ms)))

(define (elapsed-ms started-ms)
  (- (current-inexact-milliseconds) started-ms))

(define (basic-metrics steps generated-tokens started-ms
                       #:provider-mode [provider-mode #f]
                       #:attempts [attempts 1]
                       #:llm-calls [llm-calls 0]
                       #:dead-prefixes [dead-prefixes 0]
                       #:rule-time-ms [rule-time-ms 0.0]
                       #:llm-time-ms [llm-time-ms 0.0]
                       #:candidate-policy [candidate-policy 'full-vocab]
                       #:candidate-count-total [candidate-count-total 0]
                       #:candidate-count-per-step [candidate-count-per-step '()]
                       #:runtime-step-calls [runtime-step-calls 0]
                       #:check-calls-in-sampling [check-calls-in-sampling 0]
                       #:parse-guide-calls-in-sampling [parse-guide-calls-in-sampling 0]
                       #:regex-calls [regex-calls 0]
                       #:vocab-size [vocab-size #f]
                       #:allowed-token-count [allowed-token-count 0]
                       #:fast-forward-tokens [fast-forward-tokens 0]
                       #:sampling-time-ms [sampling-time-ms 0.0]
                       #:provider-session? [provider-session? #f]
                       #:unsupported-reason [unsupported-reason #f])
  (hash 'steps steps
        'generated-tokens generated-tokens
        'latency-ms (elapsed-ms started-ms)
        'attempts attempts
        'llm-calls llm-calls
        'provider-calls llm-calls
        'dead-prefixes dead-prefixes
        'dead-token-count dead-prefixes
        'rule-time-ms rule-time-ms
        'llm-time-ms llm-time-ms
        'sampling-time-ms sampling-time-ms
        'provider-mode provider-mode
        'vocab-size vocab-size
        'provider-session? provider-session?
        'candidate-policy candidate-policy
        'candidate-count-total candidate-count-total
        'candidate-count-per-step candidate-count-per-step
        'runtime-step-calls runtime-step-calls
        'check-calls-in-sampling check-calls-in-sampling
        'parse-guide-calls-in-sampling parse-guide-calls-in-sampling
        'regex-calls regex-calls
        'allowed-token-count allowed-token-count
        'fast-forward-tokens fast-forward-tokens
        'unsupported-reason unsupported-reason))

(define (make-generation-result #:status status
                                #:reason reason
                                #:text text
                                #:value value
                                #:lm-logprob lm-logprob
                                #:guide-score guide-score
                                #:beta [beta 1.0]
                                #:hard-ok? hard-ok?
                                #:low-score? [low-score? #f]
                                #:steps [steps 0]
                                #:attempts [attempts 1]
                                #:generated-tokens [generated-tokens 0]
                                #:latency-ms [latency-ms 0.0]
                                #:trace [trace '()]
                                #:metrics [metrics (hash)])
  (generation-result status
                     reason
                     text
                     value
                     lm-logprob
                     guide-score
                     (combined-score lm-logprob guide-score beta)
                     hard-ok?
                     low-score?
                     steps
                     attempts
                     generated-tokens
                     latency-ms
                     trace
                     metrics))

(define (log-softmax logits)
  (define max-logit
    (for/fold ([best -inf.0])
              ([x (in-vector logits)])
      (max best x)))
  (cond
    [(log-score-dead? max-logit)
     (for/vector ([x (in-vector logits)]) -inf.0)]
    [else
     (define log-z
       (+ max-logit
          (log
           (for/sum ([x (in-vector logits)])
             (if (log-score-dead? x) 0.0 (exp (- x max-logit)))))))
     (for/vector ([x (in-vector logits)])
       (if (log-score-dead? x) -inf.0 (- x log-z)))]))

(define (sample-id adjusted-logits rng temperature)
  (unless (and (real? temperature) (> temperature 0))
    (raise-argument-error 'sample-id "positive real?" temperature))
  (define-values (best-id _best-score)
    (for/fold ([best-id #f] [best-score -inf.0])
              ([logit (in-vector adjusted-logits)]
               [id (in-naturals)])
      (define score (+ (/ logit temperature) (gumbel rng)))
      (if (and (sampleable? logit)
               (or (not best-id) (> score best-score)))
          (values id score)
          (values best-id best-score))))
  (unless best-id
    (error 'sample-id "no tokens to sample"))
  best-id)

(define (gumbel rng)
  (define u
    (parameterize ([current-pseudo-random-generator rng])
      (max 1e-12 (min (- 1.0 1e-12) (random)))))
  (- (log (- (log u)))))
