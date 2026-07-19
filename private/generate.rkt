#lang racket/base
(require racket/generator racket/list racket/promise
         "model.rkt" "regex.rkt" "program.rkt" "domain.rkt" "cars.rkt" "weak.rkt")
(provide compile-spec attach-calibration accepts? observe observe-token-ids generation-request generate-batch
         generation-result-status generation-result-reason generation-result-token-ids
         generation-result-text generation-result-lm-logprob generation-result-latency-ms
         generation-result-tokenizer-fingerprint generation-result-posterior
         generation-result-terminal-mass generation-result-calibration-fingerprint
         generation-result-attempts generation-result-proposed-tokens generation-result-model-draws
         generation-result-trie-nodes)
(struct context (vocabulary) #:transparent) (struct policy (calibration good bad) #:transparent)
(struct compiled (model program policy) #:transparent)
(define contexts (make-weak-hasheq))
(define (model-context model)
  (hash-ref contexts model
            (lambda ()
              (define tok (model-tokenizer model))
              (define pieces (delay (for/vector ([id (in-range (vocab-size tok))]) (token-ref tok id))))
              (define value (context (make-regex-vocabulary (lambda () (force pieces)))))
              (hash-set! contexts model value) value)))
(define (compile-spec model ast)
  (model-ensure-open! 'compile-spec model)
  (define c (model-context model))
  (compiled model (compile-program ast (lambda (s) (tokenize (model-tokenizer model) s))
                                   (context-vocabulary c)) #f))
(define (attach-calibration spec calibration #:good [good 1.0] #:bad [bad 0.0])
  (unless (compiled? spec) (raise-argument-error 'attach-calibration "compiled spec" spec))
  (define (weight? x) (and (real? x) (<= 0.0 x) (< x +inf.0)))
  (unless (and (weight? good) (weight? bad) (positive? (max good bad)))
    (raise-arguments-error 'attach-calibration
                           "finite nonnegative weights, not both zero" "good" good "bad" bad))
  (define schema (program-schema (compiled-program spec))) (define fitted (calibration-schema calibration))
  (unless (and schema (equal? schema fitted)
               (equal? (rule-schema-fingerprint schema) (rule-schema-fingerprint fitted)))
    (error 'attach-calibration "calibration rule schema does not match compiled spec"))
  (define scale (max good bad))
  (compiled (compiled-model spec) (compiled-program spec) (policy calibration (/ good scale) (/ bad scale))))
(define (run compiled ids)
  (for/fold ([st (program-initial (compiled-program compiled))]) ([id (in-list ids)])
    (program-step st id)))
(define (accepts? spec value)
  (model-ensure-open! 'accepts? (compiled-model spec))
  (define tok (model-tokenizer (compiled-model spec))) (define ids (tokenize tok value))
  (and (string=? value (detokenize tok ids)) (program-accepting? (run spec ids))))
(define (observe spec value)
  (model-ensure-open! 'observe (compiled-model spec))
  (define tok (model-tokenizer (compiled-model spec))) (define ids (tokenize tok value))
  (unless (string=? value (detokenize tok ids)) (error 'observe "candidate is not tokenizer-canonical"))
  (observe-token-ids spec ids))
(define (observe-token-ids spec ids)
  (model-ensure-open! 'observe-token-ids (compiled-model spec))
  (check-token-ids 'observe-token-ids (model-tokenizer (compiled-model spec)) ids)
  (define st (run spec ids)) (define schema (program-schema (compiled-program spec)))
  (unless (program-accepting? st) (error 'observe-token-ids "candidate is not accepted by the hard program"))
  (unless schema (error 'observe-token-ids "compiled spec has no rule schema"))
  (make-observation schema (program-observe
                            (compiled-program spec) st ids
                            (lambda (part) (detokenize (model-tokenizer (compiled-model spec)) part)))))
(struct request (compiled prompt attempts draws temperature max-tokens seed deadline) #:transparent)
(define (generation-request compiled prompt #:max-attempts attempts #:max-model-draws [draws #f]
                            #:temperature [temperature 0.7] #:max-tokens [max-tokens 128]
                            #:seed [seed #f] #:deadline-ms [deadline #f])
  (unless (exact-positive-integer? attempts)
    (raise-argument-error 'generation-request "positive max-attempts" attempts))
  (when (and draws (not (exact-positive-integer? draws)))
    (raise-argument-error 'generation-request "positive max-model-draws or #f" draws))
  (request compiled prompt attempts draws temperature max-tokens seed deadline))
(struct generation-result
  (status reason token-ids text lm-logprob latency-ms tokenizer-fingerprint posterior terminal-mass
          calibration-fingerprint attempts proposed-tokens model-draws trie-nodes) #:transparent)
(struct job (compiled prompt-ids attempts draws temperature max-tokens rng trie started deadline) #:transparent)
(struct proposal (outcome ids logprob proposed draws updates terminal posterior mass) #:transparent)
(struct reset-op () #:transparent)
(struct factor-op (request) #:transparent)
(struct commit-op (id) #:transparent)

(define (request->job expected r)
  (unless (request? r) (raise-argument-error 'generate-batch "generation-request" r))
  (define spec (request-compiled r))
  (unless (eq? expected (compiled-model spec)) (error 'generate-batch "requests use different models"))
  (unless (and (real? (request-temperature r)) (> (request-temperature r) 0.0)
               (= (request-temperature r) (request-temperature r)))
    (raise-argument-error 'generate-batch "positive finite temperature" (request-temperature r)))
  (unless (exact-nonnegative-integer? (request-max-tokens r))
    (raise-argument-error 'generate-batch "nonnegative max-tokens" (request-max-tokens r)))
  (define ids (tokenize (model-tokenizer expected) (request-prompt r)))
  (define limit (provider-context-limit (model-provider expected)))
  (when (and limit (> (+ (length ids) (request-max-tokens r)) limit))
    (error 'generate-batch "request exceeds the per-lane context"))
  (job spec ids (request-attempts r) (request-draws r) (request-temperature r)
       (request-max-tokens r) (make-rng (request-seed r))
       (make-cars-trie) (box #f) (request-deadline r)))

(define (job-model j) (compiled-model (job-compiled j)))

(define (terminal-values j ids st)
  (define target (job-compiled j)) (define guidance (compiled-policy target))
  (cond
    [(not guidance) (values #f 1.0)]
    [else
     (define labels (program-observe
                     (compiled-program target) st ids
                     (lambda (part) (detokenize (model-tokenizer (job-model j)) part))))
     (define p (calibration-posterior/row (policy-calibration guidance) labels))
     (define mass (+ (* (policy-good guidance) p) (* (policy-bad guidance) (- 1.0 p))))
     (unless (and (real? p) (<= 0.0 p 1.0) (real? mass) (<= 0.0 mass 1.0))
       (error 'generate-batch "calibration produced invalid terminal values"))
     (values p mass)]))
(define (terminal j ids st logprob proposed draws updates node)
  (define-values (posterior mass) (terminal-values j ids st))
  (define old (if node (cars-node-mass node) 1.0))
  (cond [(or (<= old 0.0) (> mass (+ old 1e-12)))
         (proposal 'internal-invalid ids logprob proposed draws updates node posterior mass)]
        [else
         (define accepted?
           (< (parameterize ([current-pseudo-random-generator (job-rng j)]) (random))
              (max 0.0 (min 1.0 (/ mass old)))))
         (proposal (if accepted? 'accepted (if (zero? mass) 'threshold-rejected 'posterior-rejected))
                   ids logprob proposed draws updates node posterior mass)]))

(define (attempt j emit remaining reset?)
  (define program (compiled-program (job-compiled j))) (define provider (model-provider (job-model j)))
  (define stop (provider-vocab-size provider)) (define eogs (provider-eog-token-ids provider))
  (when reset? (emit (reset-op)))
  (let loop ([depth 0] [rev '()] [st (program-initial program)]
             [node (cars-trie-root (job-trie j))] [logprob 0.0]
             [proposed 0] [draws 0] [updates '()])
    (cond
      [(and remaining (>= draws remaining))
       (proposal 'draw-budget (reverse rev) logprob proposed draws '() #f #f 0.0)]
      [(>= depth (job-max-tokens j))
       (define child (and node (cars-node-child! (job-trie j) node stop 1.0)))
       (if (program-accepting? st)
           (terminal j (reverse rev) st logprob proposed draws updates child)
           (proposal 'hard-invalid (reverse rev) logprob proposed draws updates child #f 0.0))]
      [else
       (define domain
         (or (and node (cars-node-domain-value node))
             (domain-force-membership (program-domain st) eogs (program-accepting? st))))
       (define selection
         (emit (factor-op (factor-request (job-temperature j) domain
                                          (and node (cars-node-domain-value node) #t)
                                          (if node (cars-node-child-masses node) '())
                                          (parameterize ([current-pseudo-random-generator (job-rng j)]) (random))))))
       (unless (factor-selection? selection) (error 'cars "proposal envelope is empty"))
       (define id (factor-selection-id selection))
       (define child (and node (cars-node-child! (job-trie j) node id
                                                 (factor-selection-base-probability selection))))
       (define next-updates
         (cond [(not node) updates]
               [(cars-node-domain-value node)
                (cars-node-check-domain! node domain (factor-selection-frontier-mass selection)) updates]
               [else (cons (make-cars-domain-update node domain
                                                    (factor-selection-frontier-mass selection)) updates)]))
       (define next-log (+ logprob (factor-selection-base-logprob selection)))
       (cond
         [(member id eogs)
          (if (program-accepting? st)
              (terminal j (reverse rev) st next-log proposed (add1 draws) next-updates child)
              (proposal 'hard-invalid (reverse rev) next-log proposed (add1 draws)
                        next-updates child #f 0.0))]
         [else
          (define next (program-step st id))
          (if (program-dead? next)
              (proposal 'hard-invalid (reverse (cons id rev)) next-log (add1 proposed) (add1 draws)
                        next-updates child #f 0.0)
              (begin (emit (commit-op id))
                     (loop (add1 depth) (cons id rev) next child next-log
                           (add1 proposed) (add1 draws) next-updates)))])])))

(define (failure j start status reason attempts proposed draws)
  (define guidance (compiled-policy (job-compiled j)))
  (generation-result status reason '() "" #f (- (current-inexact-milliseconds) start)
                     (tokenizer-fingerprint (model-tokenizer (job-model j))) #f #f
                     (and guidance (calibration-fingerprint (policy-calibration guidance)))
                     attempts proposed draws
                     (cars-trie-node-count (job-trie j))))
(define (sample j emit)
  (define start (current-inexact-milliseconds)) (set-box! (job-started j) start)
  (define guidance (compiled-policy (job-compiled j)))
  (let loop ([number 1] [proposed 0] [draws 0])
    (cond
      [(and (job-deadline j) (>= (- (current-inexact-milliseconds) start) (job-deadline j)))
       (failure j start 'not-found-time-budget "deadline exhausted" (sub1 number) proposed draws)]
      [(> number (job-attempts j))
       (failure j start 'not-found-attempt-budget "attempt budget exhausted" (sub1 number) proposed draws)]
      [(and (job-draws j) (>= draws (job-draws j)))
       (failure j start 'not-found-model-draw-budget "draw budget exhausted" (sub1 number) proposed draws)]
      [(<= (cars-node-mass (cars-trie-root (job-trie j))) 0.0)
       (failure j start 'not-found-support "support is empty" (sub1 number) proposed draws)]
      [else
       (define p (attempt j emit (and (job-draws j) (- (job-draws j) draws)) (> number 1)))
       (define next-proposed (+ proposed (proposal-proposed p)))
       (define next-draws (+ draws (proposal-draws p)))
       (cond [(eq? (proposal-outcome p) 'internal-invalid)
              (failure j start 'internal-invalid "invalid terminal envelope"
                       (sub1 number) proposed draws)]
             [(eq? (proposal-outcome p) 'draw-budget)
              (failure j start 'not-found-model-draw-budget "draw budget exhausted"
                       (sub1 number) next-proposed next-draws)]
             [else
              (cars-commit! (proposal-updates p) (proposal-terminal p) (proposal-mass p))
              (if (eq? (proposal-outcome p) 'accepted)
                  (generation-result 'found #f (proposal-ids p)
                                     (detokenize (model-tokenizer (job-model j)) (proposal-ids p))
                                     (proposal-logprob p) (- (current-inexact-milliseconds) start)
                                     (tokenizer-fingerprint (model-tokenizer (job-model j)))
                                     (proposal-posterior p)
                                     (and guidance (proposal-mass p))
                                     (and guidance (calibration-fingerprint (policy-calibration guidance)))
                                     number
                                     next-proposed next-draws (cars-trie-node-count (job-trie j)))
                  (loop (add1 number) next-proposed next-draws))])])))

(define (worker j) (generator () (sample j (lambda (op) (yield op)))))
(define (run-cohort provider jobs)
  (define width (provider-cohort-width provider))
  (define n (length jobs))
  (define prompts (append (map job-prompt-ids jobs)
                          (make-list (- width n) (job-prompt-ids (car jobs)))))
  (define cohort #f) (define poisoned? #f)
  (define workers (list->vector (map worker jobs)))
  (define events (make-vector n #f)) (define results (make-vector n #f))
  (define filler (car (provider-eog-token-ids provider)))
  (define (resume! lane [value #f] [send? #f])
    (define out (if send? ((vector-ref workers lane) value) ((vector-ref workers lane))))
    (if (generation-result? out)
        (begin (vector-set! results lane out) (vector-set! events lane #f))
        (vector-set! events lane out)))
  (define (drive!)
    (for ([lane (in-range n)]) (resume! lane))
    (let loop ()
      (unless (for/and ([x (in-vector results)]) x)
        (define resets (for/list ([i (in-range n)] #:when (reset-op? (vector-ref events i))) i))
        (define factors (for/list ([i (in-range n)] #:when (factor-op? (vector-ref events i)))
                          (cons i (factor-op-request (vector-ref events i)))))
        (cond [(pair? resets)
               (provider-restore-lanes! provider cohort resets)
               (for ([i resets]) (resume! i (void) #t))]
              [(pair? factors)
               (for ([entry factors] [selection (provider-sample-factors provider cohort factors)])
                 (resume! (car entry) selection #t))]
              [else
               (unless (for/and ([i (in-range n)])
                         (or (vector-ref results i) (commit-op? (vector-ref events i))))
                 (error 'generate-batch "invalid scheduler state"))
               (provider-decode! provider cohort
                                 (for/list ([i (in-range width)])
                                   (if (and (< i n) (commit-op? (vector-ref events i)))
                                       (commit-op-id (vector-ref events i)) filler)))
               (for ([i (in-range n)] #:when (commit-op? (vector-ref events i)))
                 (resume! i (void) #t))])
        (loop)))
    (vector->list results))
  (dynamic-wind void
    (lambda ()
      (with-handlers ([exn:fail? (lambda (e) (set! poisoned? #t)
                                   (for/list ([j jobs] [i (in-naturals)])
                                     (or (vector-ref results i)
                                         (failure j (or (unbox (job-started j)) (current-inexact-milliseconds))
                                                  'backend-error (exn-message e) 0 0 0))))])
        (set! cohort (provider-open-cohort provider prompts)) (drive!)))
    (lambda () (when cohort (provider-close-cohort! provider cohort poisoned?)))))

(define (chunks xs width)
  (let loop ([remaining xs] [answer '()])
    (if (null? remaining)
        (reverse answer)
        (let take ([rest remaining] [left width] [part '()])
          (if (or (zero? left) (null? rest))
              (loop rest (cons (reverse part) answer))
              (take (cdr rest) (sub1 left) (cons (car rest) part)))))))
(define (generate-batch requests)
  (unless (list? requests) (raise-argument-error 'generate-batch "list?" requests))
  (cond [(null? requests) '()]
        [else
         (define first (car requests))
         (unless (request? first) (raise-argument-error 'generate-batch "generation requests" requests))
         (define model (compiled-model (request-compiled first)))
         (model-enter-generation! model)
         (dynamic-wind void
           (lambda ()
             (define jobs (map (lambda (r) (request->job model r)) requests))
             (define provider (model-provider model))
             (append-map (lambda (part) (run-cohort provider part))
                         (chunks jobs (provider-cohort-width provider))))
           (lambda () (model-leave-generation! model)))]))
