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
(struct token-selection (id token raw-logit lm-logprob adjustment dead-count)
  #:transparent)

(define deadline-poll-interval 1)

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
                      #:unique unique)
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
                         #:unique [unique 'none])
  (define guide (ensure-guide 'generate-stream g))
  (let loop ([attempt 0] [cache '()])
    (define result
      (generate-one p prompt guide
                    #:beta beta
                    #:lambda lambda-weight
                    #:temperature temperature
                    #:seed (attempt-seed seed attempt)
                    #:deadline-ms deadline-ms
                    #:max-tokens max-tokens))
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
                      #:max-tokens max-tokens)
  (define started-ms (current-inexact-milliseconds))
  (define rng (make-rng seed))
  (define finite (finite-candidates guide))
  (cond
    [(pair? finite) (best-finite p prompt finite beta started-ms)]
    [else
     (define vocab-vec (list->vector (provider-vocab p)))
     (generate-text p prompt guide beta lambda-weight temperature rng deadline-ms max-tokens started-ms vocab-vec)]))

(define (stream-take/list s n)
  (for/list ([item (in-stream s)] [_ (in-range n)])
    item))

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

(define (transition-adjustment state token last-score last-potential beta lambda-weight)
  (define guide (rt-state-guide state))
  (if (and (eq? (guide-kind guide) 'text)
           (not (second (guide-data guide))))
      (text-transition-adjustment state token last-score last-potential beta lambda-weight)
      (slow-transition-adjustment state token last-score last-potential beta lambda-weight)))

(define (slow-transition-adjustment state token last-score last-potential beta lambda-weight)
  (define next-state (guide-step state token))
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

(define (text-transition-adjustment state token last-score last-potential beta lambda-weight)
  (define guide (rt-state-guide state))
  (match-define (list max-tokens _until watchers) (guide-data guide))
  (define text (string-append (rt-state-text state) token))
  (cond
    [(> (string-length text) max-tokens)
     (values (rt-state guide text 'dead neg-inf 0.0 #f (list 'budget-dead))
             neg-inf
             #t)]
    [else
     (define-values (ok? guide-score) (watcher-score watchers text))
     (if ok?
         (let* ([potential 0.0]
                [delta-score (- guide-score last-score)]
                [delta-potential (- potential last-potential)]
                [status (if (>= (string-length text) max-tokens) 'done 'live)]
                [value (and (eq? status 'done) text)]
                [next-state (rt-state guide
                                      text
                                      status
                                      guide-score
                                      potential
                                      value
                                      (watcher-trace watchers text))])
           (values next-state
                   (* beta (+ delta-score (* lambda-weight delta-potential)))
                   #f))
         (values (rt-state guide text 'dead neg-inf 0.0 #f (watcher-trace watchers text))
                 neg-inf
                 #t))]))

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
                            #:score? [score? #t])
  (define guide (rt-state-guide state))
  (cond
    [(not (eq? (guide-kind guide) 'lit))
     (values state prefix 0.0 0)]
    [else
     (define literal (guide-data guide))
     (define consumed (rt-state-text state))
     (cond
       [(not (string-prefix-of? consumed literal))
        (values state prefix neg-inf 0)]
       [else
        (define remaining (substring literal (string-length consumed)))
        (define next-state (guide-step state remaining))
        (define next-prefix (string-append prefix remaining))
        (define lm-logprob
          (if score? (sequence-logprob provider prompt remaining) 0.0))
        (define scoring-calls
          (if score? (length (tokenize provider remaining)) 0))
        (values next-state next-prefix lm-logprob scoring-calls)])]))

(define (string-prefix-of? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (generate-text p prompt guide beta lambda-weight temperature rng deadline-ms max-tokens started-ms vocab-vec)
  (let loop ([step 0]
             [prefix ""]
             [state (guide-init guide)]
             [last-score 0.0]
             [last-potential 0.0]
             [lm-score 0.0]
             [llm-calls 0]
             [dead-prefixes 0]
             [rule-time-ms 0.0]
             [llm-time-ms 0.0])
    (cond
      [(deadline-expired? started-ms deadline-ms)
       (budget-error-result state prefix lm-score beta step started-ms p llm-calls
                            dead-prefixes rule-time-ms llm-time-ms
                            "deadline exhausted")]
      [(>= step max-tokens) (result-from-check guide prefix lm-score 'not-found-budget
                                               "token budget exhausted"
                                               beta
                                               step
                                               started-ms
                                               p
                                               llm-calls
                                               dead-prefixes
                                               rule-time-ms
                                               llm-time-ms)]
      [else
       (define llm-start (current-inexact-milliseconds))
       (define logits (provider-next-logit-vector p prompt prefix))
       (define next-llm-time-ms (+ llm-time-ms (- (current-inexact-milliseconds) llm-start)))
       (cond
         [(deadline-expired? started-ms deadline-ms)
          (budget-error-result state prefix lm-score beta step started-ms p llm-calls
                               dead-prefixes rule-time-ms next-llm-time-ms
                               "deadline exhausted after provider logits")]
         [else
          (define next-llm-calls (add1 llm-calls))
          (define rule-start (current-inexact-milliseconds))
          (define selection
            (select-token/full-vocab state
                                     logits
                                     vocab-vec
                                     last-score
                                     last-potential
                                     beta
                                     lambda-weight
                                     temperature
                                     rng
                                     started-ms
                                     deadline-ms))
          (define next-rule-time-ms (+ rule-time-ms (- (current-inexact-milliseconds) rule-start)))
          (cond
            [(eq? selection 'budget)
             (budget-error-result state prefix lm-score beta step started-ms p
                                  next-llm-calls dead-prefixes next-rule-time-ms
                                  next-llm-time-ms
                                  "deadline exhausted during full-vocabulary sampling pass")]
            [(not (token-selection-id selection))
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
                                      #:rule-time-ms next-rule-time-ms
                                      #:llm-time-ms next-llm-time-ms))]
            [else
             (define-values (next-state _adjustment _dead-transition?)
               (transition-adjustment state
                                      (token-selection-token selection)
                                      last-score
                                      last-potential
                                      beta
                                      lambda-weight))
             (define next-prefix (string-append prefix (token-selection-token selection)))
             (define next-lm-score
               (log-score-add lm-score (token-selection-lm-logprob selection)))
             (define next-dead-prefixes
               (+ dead-prefixes (token-selection-dead-count selection)))
             (if (done? next-state)
                 (result-from-state next-state next-lm-score beta step started-ms p
                                    next-llm-calls next-dead-prefixes
                                    next-rule-time-ms next-llm-time-ms)
                 (loop (add1 step)
                       next-prefix
                       next-state
                       (state-score next-state)
                       (state-potential next-state)
                       next-lm-score
                       next-llm-calls
                       next-dead-prefixes
                       next-rule-time-ms
                       next-llm-time-ms))])])])))

(define (select-token/full-vocab state logits vocab-vec last-score last-potential beta lambda-weight temperature rng started-ms deadline-ms)
  (unless (and (real? temperature) (> temperature 0))
    (raise-argument-error 'generate "positive real temperature" temperature))
  (define vocab-size (vector-length vocab-vec))
  (define-values (best-id best-token best-raw-logit best-adjustment best-score dead-count max-logit exp-sum budget?)
    (for/fold ([best-id #f]
               [best-token #f]
               [best-raw-logit -inf.0]
               [best-adjustment 0.0]
               [best-score -inf.0]
               [dead-count 0]
               [max-logit -inf.0]
               [exp-sum 0.0]
               [budget? #f])
              ([id (in-range vocab-size)])
      (cond
        [budget?
         (values best-id best-token best-raw-logit best-adjustment best-score
                 dead-count max-logit exp-sum budget?)]
        [(and (zero? (remainder id deadline-poll-interval))
              (deadline-expired? started-ms deadline-ms))
         (values best-id best-token best-raw-logit best-adjustment best-score
                 dead-count max-logit exp-sum #t)]
        [else
         (define noise (gumbel rng))
         (define logit (vector-ref logits id))
         (define-values (next-max next-sum)
           (logsumexp-accumulate max-logit exp-sum logit))
         (cond
           [(log-score-dead? logit)
            (values best-id best-token best-raw-logit best-adjustment best-score
                    (add1 dead-count) next-max next-sum #f)]
           [else
            (define token (vector-ref vocab-vec id))
            (define-values (_next-state adjustment dead-transition?)
              (transition-adjustment state token last-score last-potential beta lambda-weight))
            (define adjusted
              (if dead-transition? neg-inf (+ logit adjustment)))
            (cond
              [(not (sampleable? adjusted))
               (values best-id best-token best-raw-logit best-adjustment best-score
                       (add1 dead-count) next-max next-sum #f)]
              [else
               (define score (+ (/ adjusted temperature) noise))
               (if (or (not best-id) (> score best-score))
                   (values id token logit adjustment score dead-count next-max next-sum #f)
                   (values best-id best-token best-raw-logit best-adjustment best-score
                           dead-count next-max next-sum #f))])])])))
  (cond
    [budget? 'budget]
    [(not best-id)
     (token-selection #f #f -inf.0 -inf.0 0.0 dead-count)]
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
                      dead-count)]))

(define (logsumexp-accumulate max-logit exp-sum logit)
  (cond
    [(log-score-dead? logit) (values max-logit exp-sum)]
    [(log-score-dead? max-logit) (values logit 1.0)]
    [(> logit max-logit)
     (values logit (+ (* exp-sum (exp (- max-logit logit))) 1.0))]
    [else
     (values max-logit (+ exp-sum (exp (- logit max-logit))))]))

(define (result-from-state state lm-score beta step started-ms p llm-calls dead-prefixes rule-time-ms llm-time-ms)
  (make-generation-result
   #:status 'found
   #:reason #f
   #:text (rt-state-text state)
   #:value (state-value state)
   #:lm-logprob lm-score
   #:guide-score (state-score state)
   #:beta beta
   #:hard-ok? #t
   #:steps (add1 step)
   #:generated-tokens (add1 step)
   #:latency-ms (elapsed-ms started-ms)
   #:metrics (basic-metrics (add1 step) (add1 step) started-ms
                            #:provider-mode (provider-mode p)
                            #:llm-calls llm-calls
                            #:dead-prefixes dead-prefixes
                            #:rule-time-ms rule-time-ms
                            #:llm-time-ms llm-time-ms)
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

(define (budget-error-result state s lm-score beta step started-ms p llm-calls dead-prefixes rule-time-ms llm-time-ms reason)
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
                            #:llm-time-ms llm-time-ms)))

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
                       #:llm-time-ms [llm-time-ms 0.0])
  (hash 'steps steps
        'generated-tokens generated-tokens
        'latency-ms (elapsed-ms started-ms)
        'attempts attempts
        'llm-calls llm-calls
        'dead-prefixes dead-prefixes
        'rule-time-ms rule-time-ms
        'llm-time-ms llm-time-ms
        'provider-mode provider-mode))

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
