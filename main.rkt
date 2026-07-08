#lang typed/racket/base

(require racket/list
         racket/string
         (only-in "private/logits.rkt"
                  LogitsView
                  check-logits-view)
         (only-in "private/model.rkt"
                  TokenId
                  TokenIds
                  ProviderMode
                  Tokenizer
                  Provider
                  Model
                  tokenize
                  detokenize
                  token-ref
                  vocab-size
                  provider-next-logits
                  provider-session-supported?
                  provider-vocab-size
                  provider-mode
                  provider-start-session
                  provider-next-logits/session
                  provider-commit-token!
                  provider-end-session!
                  model-tokenizer
                  model-provider
                  model-metadata
                  model-close!)
         (only-in "private/filter.rkt"
                  Score
                  Filter
                  Watcher
                  neg-inf
                  log-score-add
                  log-score-dead?
                  make-lit-filter
                  make-rx-filter
                  make-pure-filter
                  make-choice-filter
                  make-seq-filter
                  make-repeat-filter
                  make-bind-filter
                  make-score-filter
                  make-text-filter
                  make-rank-watcher
                  make-ban-watcher
                  make-weighted-rule
                  make-weighted-watcher
                  FilterState
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
                  filter-trace)
         "private/regex.rkt"
         (only-in "private/sampling.rkt"
                  CandidatePolicy
                  make-sampler
                  token-selection-id
                  token-selection-lm-logprob
                  token-selection-dead-count
                  token-selection-next-state
                  token-selection-candidate-count
                  sampler-select-token))

(provide Score
         Model
         FilterBuilder
         WatcherBuilder
         CandidatePolicy
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
         (struct-out generation-metrics)
         (struct-out generation-result)
         generate)

;; Regex internals live in private/regex.rkt. main.rkt keeps the public
;; builder facade and tokenizer-specific wiring.

(: instantiate-regex-for-tokenizer (-> RegexProgram Tokenizer RegexMachine))
(define (instantiate-regex-for-tokenizer program tok)
  (define token-texts
    (for/vector : (Vectorof String) ([id : Natural (in-range (vocab-size tok))])
      (token-ref tok id)))
  (instantiate-regex-machine program token-texts))

(define-type FilterBuilder (-> Tokenizer Filter))
(define-type WatcherBuilder (-> Tokenizer Watcher))

;; Public filter builders. They are immutable descriptions that compile to
;; token-native filters only when the caller applies them to a tokenizer.


(: lit (-> String FilterBuilder))
(define (lit source)
  (lambda ([tok : Tokenizer])
    (make-lit-filter (tokenize tok source))))

(: rx (-> String FilterBuilder))
(define (rx pattern)
  (define program (parse-regex-program pattern))
  (lambda ([tok : Tokenizer])
    (make-rx-filter (instantiate-regex-for-tokenizer program tok))))

(: pure (-> Any FilterBuilder))
(define (pure value)
  (lambda ([_tok : Tokenizer])
    (make-pure-filter value)))

(: choice (-> (Listof FilterBuilder) FilterBuilder))
(define (choice options)
  (lambda ([tok : Tokenizer])
    (make-choice-filter
     (for/list : (Listof Filter) ([option (in-list options)])
       (option tok)))))

(: seq (-> (Listof FilterBuilder) FilterBuilder))
(define (seq children)
  (lambda ([tok : Tokenizer])
    (make-seq-filter
     (for/list : (Listof Filter) ([child (in-list children)])
       (child tok)))))

(: repeat (-> Natural Natural FilterBuilder FilterBuilder))
(define (repeat min-count max-count item)
  (lambda ([tok : Tokenizer])
    (make-repeat-filter min-count max-count (item tok))))

(: bind (-> FilterBuilder (-> Any FilterBuilder) FilterBuilder))
(define (bind first continue)
  (lambda ([tok : Tokenizer])
    (make-bind-filter
     (first tok)
     (lambda ([value : Any])
       ((continue value) tok)))))

(: score (-> Real FilterBuilder Boolean FilterBuilder))
(define (score amount child ban?)
  (lambda ([tok : Tokenizer])
    (make-score-filter amount (child tok) ban?)))

(: text (-> Natural (Listof WatcherBuilder) FilterBuilder))
(define (text max-tokens watchers)
  (lambda ([tok : Tokenizer])
    (make-text-filter
     max-tokens
     (for/list : (Listof Watcher) ([watcher (in-list watchers)])
       (watcher tok)))))

(: rank (-> Real String WatcherBuilder))
(define (rank amount source)
  (lambda ([tok : Tokenizer])
    (make-rank-watcher amount (tokenize tok source))))

(: ban (-> String WatcherBuilder))
(define (ban source)
  (lambda ([tok : Tokenizer])
    (make-ban-watcher (tokenize tok source))))

(: weight (-> (Listof String) (Listof (Pairof Real String)) WatcherBuilder))
(define (weight samples specs)
  (when (null? samples)
    (raise-argument-error 'weight "non-empty list of strings" samples))
  (when (null? specs)
    (raise-argument-error 'weight "non-empty watcher spec list" specs))
  (lambda ([tok : Tokenizer])
    (make-weighted-watcher
     (for/list ([spec (in-list specs)])
       (define source (cdr spec))
       (define pos (add1 (count (lambda ([sample : String])
                                  (string-contains? sample source))
                                samples)))
       (define neg (add1 (- (length samples) (sub1 pos))))
       (define raw : Real (assert (log (/ pos neg)) real?))
       (define oriented
         (if (negative? (car spec)) (- (abs raw)) (abs raw)))
       (make-weighted-rule oriented (tokenize tok source) source)))))


;; Generation



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
   [text : String]
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

(: generate
   (->* (Model String FilterBuilder)
        (#:beta Real
         #:lambda Real
         #:temperature Real
         #:seed (Option Integer)
         #:deadline-ms (Option Real)
         #:max-tokens Natural
         #:candidate-policy CandidatePolicy)
        generation-result))
(define (generate m prompt builder
                  #:beta [beta 1.0]
                  #:lambda [lambda-weight 0.5]
                  #:temperature [temperature 0.7]
                  #:seed [seed #f]
                  #:deadline-ms [deadline-ms #f]
                  #:max-tokens [max-tokens 128]
                  #:candidate-policy [candidate-policy 'full-vocab])
  (define tok (model-tokenizer m))
  (define p (model-provider m))
  (define prompt-ids (tokenize tok prompt))
  (define f (builder tok))
  (define result
    (generate/internal p
                       prompt-ids
                       f
                       #:beta beta
                       #:lambda lambda-weight
                       #:temperature temperature
                       #:seed seed
                       #:deadline-ms deadline-ms
                       #:max-tokens max-tokens
                       #:candidate-policy candidate-policy))
  (result-with-text result (detokenize tok (generation-result-token-ids result))))

(: generate/internal
   (->* (Provider TokenIds Filter)
        (#:beta Real
         #:lambda Real
         #:temperature Real
         #:seed (Option Integer)
         #:deadline-ms (Option Real)
         #:max-tokens Natural
         #:candidate-policy CandidatePolicy)
        generation-result))
(define (generate/internal p prompt-ids f
                           #:beta [beta 1.0]
                           #:lambda [lambda-weight 0.5]
                           #:temperature [temperature 0.7]
                           #:seed [seed #f]
                           #:deadline-ms [deadline-ms #f]
                           #:max-tokens [max-tokens 128]
                           #:candidate-policy [candidate-policy 'full-vocab])
  (define started (current-inexact-milliseconds))
  (define sampler
    (make-sampler (provider-vocab-size p)
                  candidate-policy
                  beta
                  lambda-weight
                  temperature
                  seed))
  (define session? (provider-session-supported? p))
  (define session : (Option Any)
    (and session? ((assert (provider-start-session p) values) prompt-ids)))
  (: next-logits (-> TokenIds LogitsView))
  (define (next-logits prefix-ids)
    (if session?
        (let ([logits ((assert (provider-next-logits/session p) values)
                       (assert session values))])
          (check-logits-view 'provider-next-logits/session logits (provider-vocab-size p))
          logits)
        (provider-next-logits p prompt-ids prefix-ids)))
  (: commit! (-> TokenId Void))
  (define (commit! id)
    (when session?
      ((assert (provider-commit-token! p) values) (assert session values) id)))
  (: end-session! (-> Void))
  (define (end-session!)
    (when session?
      ((assert (provider-end-session! p) values) (assert session values))))
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
       (define selection
         (sampler-select-token sampler f state logits last-score last-potential))
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

(: make-result
   (->* (Symbol (Option String) TokenIds Any Real Real Real Boolean Natural Real
                Provider Boolean CandidatePolicy Natural Natural Natural (Listof Natural))
        (#:trace (Listof Any))
        generation-result))
(define (make-result status reason ids value lm-score f-score beta hard-ok? steps started
                     p session? candidate-policy llm-calls dead-count candidate-total candidate-counts
                     #:trace [trace '()])
  (generation-result status reason ids "" value lm-score f-score
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

(: result-with-text (-> generation-result String generation-result))
(define (result-with-text result text)
  (generation-result
   (generation-result-status result)
   (generation-result-reason result)
   (generation-result-token-ids result)
   text
   (generation-result-value result)
   (generation-result-lm-logprob result)
   (generation-result-filter-score result)
   (generation-result-total-score result)
   (generation-result-hard-ok? result)
   (generation-result-steps result)
   (generation-result-generated-tokens result)
   (generation-result-latency-ms result)
   (generation-result-trace result)
   (generation-result-metrics result)))

(: combined-score (-> Real Real Real Real))
(define (combined-score lm local beta)
  (if (or (log-score-dead? lm) (log-score-dead? local))
      neg-inf
      (+ lm (* beta local))))

(: deadline-expired? (-> Real (Option Real) Boolean))
(define (deadline-expired? started deadline-ms)
  (and deadline-ms
       (>= (- (current-inexact-milliseconds) started) deadline-ms)))
