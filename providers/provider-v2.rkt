#lang typed/racket/base

(require "../grammar.rkt")

(provide TokenId
         Logit
         LogitVector
         ProviderMode
         ProviderInfo
         ProviderState
         ProviderTrace
         LogitsResult
         LogitProvider
         Provider
         make-provider-info
         provider-info?
         provider-info-name
         provider-info-mode
         provider-info-model-id
         provider-info-model-hash
         provider-info-vocab-size
         (struct-out provider-state)
         (struct-out provider-trace)
         (struct-out logits-result)
         (struct-out provider)
         provider-reset
         provider-exact?
         provider-truncated?
         require-exact-provider
         truncate-provider
         token-oracle->provider
         provider->token-oracle)

(define-type TokenId Natural)
(define-type Logit Flonum)
(define-type LogitVector (Vectorof Logit))
(define-type ProviderMode (U 'exact-full-vocab 'truncated-top-k 'compat-no-logits))

(struct provider-info-record
  ([name : Symbol]
   [mode : ProviderMode]
   [model-id : String]
   [model-hash : (Option String)]
   [vocab-size : Natural])
  #:transparent)
(define-type ProviderInfo provider-info-record)

(: make-provider-info (-> Symbol ProviderMode String (Option String) Natural ProviderInfo))
(define (make-provider-info name mode model-id model-hash vocab-size)
  (provider-info-record name mode model-id model-hash vocab-size))

(: provider-info? (-> Any Boolean))
(define (provider-info? x)
  (provider-info-record? x))

(: provider-info-name (-> ProviderInfo Symbol))
(define (provider-info-name info)
  (provider-info-record-name info))

(: provider-info-mode (-> ProviderInfo ProviderMode))
(define (provider-info-mode info)
  (provider-info-record-mode info))

(: provider-info-model-id (-> ProviderInfo String))
(define (provider-info-model-id info)
  (provider-info-record-model-id info))

(: provider-info-model-hash (-> ProviderInfo (Option String)))
(define (provider-info-model-hash info)
  (provider-info-record-model-hash info))

(: provider-info-vocab-size (-> ProviderInfo Natural))
(define (provider-info-vocab-size info)
  (provider-info-record-vocab-size info))

(struct provider-state
  ([opaque : Any])
  #:transparent)
(define-type ProviderState provider-state)

(struct provider-trace
  ([prompt-tokens : Natural]
   [prefix-tokens : Natural]
   [cache-hit? : Boolean]
   [elapsed-ms : Nonnegative-Flonum]
   [truncated-mass : (Option Flonum)])
  #:transparent)
(define-type ProviderTrace provider-trace)

(struct logits-result
  ([logits : LogitVector]
   [state : ProviderState]
   [trace : ProviderTrace])
  #:transparent)
(define-type LogitsResult logits-result)

(define-type LogitProvider
  (-> EvaluatedProgram String ProviderState LogitsResult))

(struct provider
  ([info : ProviderInfo]
   [initial-state : ProviderState]
   [tokenize : (-> String (Listof TokenId))]
   [detokenize : (-> (Listof TokenId) String)]
   [next-logits : LogitProvider])
  #:transparent)
(define-type Provider provider)

(: provider-reset (-> Provider ProviderState))
(define (provider-reset p)
  (provider-initial-state p))

(: provider-exact? (-> Provider Boolean))
(define (provider-exact? p)
  (eq? (provider-info-mode (provider-info p)) 'exact-full-vocab))

(: provider-truncated? (-> Provider Boolean))
(define (provider-truncated? p)
  (eq? (provider-info-mode (provider-info p)) 'truncated-top-k))

(: require-exact-provider (-> Provider Void))
(define (require-exact-provider p)
  (unless (provider-exact? p)
    (error 'require-exact-provider
           "provider mode ~a cannot be used for exact distribution tests"
           (provider-info-mode (provider-info p)))))

(: truncate-provider (-> Provider Natural Provider))
(define (truncate-provider p k)
  (define info (provider-info p))
  (provider
   (make-provider-info (provider-info-name info)
                       'truncated-top-k
                       (provider-info-model-id info)
                       (provider-info-model-hash info)
                       (provider-info-vocab-size info))
   (provider-initial-state p)
   (provider-tokenize p)
   (provider-detokenize p)
   (lambda ([transcript : EvaluatedProgram] [prefix : String] [state : ProviderState])
     (define result ((provider-next-logits p) transcript prefix state))
     (define logits (logits-result-logits result))
     (define kept (top-k-scores logits k))
     (define truncated (mask-logits logits kept))
     (define trace (logits-result-trace result))
     (define mass
       (and (eq? (provider-info-mode info) 'exact-full-vocab)
            (dropped-softmax-mass logits kept)))
     (logits-result truncated
                    (logits-result-state result)
                    (struct-copy provider-trace trace
                                 [truncated-mass mass])))))

(: token-oracle->provider
   (->* (TokenOracle)
        (#:name Symbol
         #:model-id String
         #:model-hash (Option String)
         #:vocab (Listof String)
         #:mode ProviderMode)
        Provider))
(define (token-oracle->provider oracle
                                #:name [name 'token-oracle]
                                #:model-id [model-id "token-oracle"]
                                #:model-hash [model-hash #f]
                                #:vocab [vocab '()]
                                #:mode [mode 'compat-no-logits])
  (define vocab-size (length vocab))
  (provider
   (make-provider-info name mode model-id model-hash vocab-size)
   (provider-state 'token-oracle)
   (lambda ([text : String]) (tokenize-vocab vocab text))
   (lambda ([ids : (Listof TokenId)]) (detokenize-vocab vocab ids))
   (lambda ([transcript : EvaluatedProgram] [prefix : String] [state : ProviderState])
     (define candidates (oracle transcript prefix))
     (logits-result (candidates->logits vocab candidates)
                    state
                    (provider-trace 0
                                    (length (tokenize-vocab vocab prefix))
                                    #f
                                    0.0
                                    #f)))))

(: provider->token-oracle (-> Provider TokenOracle))
(define (provider->token-oracle p)
  (lambda ([transcript : EvaluatedProgram] [prefix : String])
    (define result
      ((provider-next-logits p) transcript prefix (provider-initial-state p)))
    (define logits (logits-result-logits result))
    (for/list : (Listof token-candidate) ([i (in-range (vector-length logits))]
                                          #:when (usable-logit? (vector-ref logits i)))
      (define id (assert i exact-nonnegative-integer?))
      (token-candidate ((provider-detokenize p) (list id))
                       (vector-ref logits i)))))

;; Logit truncation

(struct token-score
  ([id : TokenId]
   [logit : Logit])
  #:transparent)

(: top-k-scores (-> LogitVector Natural (Listof token-score)))
(define (top-k-scores logits k)
  (for/fold ([kept : (Listof token-score) '()])
            ([i (in-range (vector-length logits))])
    (define id (assert i exact-nonnegative-integer?))
    (take-up-to k
                (insert-score (token-score id (vector-ref logits i))
                              kept))))

(: insert-score (-> token-score (Listof token-score) (Listof token-score)))
(define (insert-score item items)
  (cond
    [(null? items) (list item)]
    [(score-better? item (car items)) (cons item items)]
    [else (cons (car items) (insert-score item (cdr items)))]))

(: score-better? (-> token-score token-score Boolean))
(define (score-better? left right)
  (or (> (token-score-logit left) (token-score-logit right))
      (and (= (token-score-logit left) (token-score-logit right))
           (< (token-score-id left) (token-score-id right)))))

(: take-up-to (All (A) (-> Natural (Listof A) (Listof A))))
(define (take-up-to n xs)
  (cond
    [(or (zero? n) (null? xs)) '()]
    [else (cons (car xs) (take-up-to (sub1 n) (cdr xs)))]))

(: mask-logits (-> LogitVector (Listof token-score) LogitVector))
(define (mask-logits logits kept)
  (for/vector : LogitVector ([i (in-range (vector-length logits))])
    (define id (assert i exact-nonnegative-integer?))
    (if (kept-id? id kept)
        (vector-ref logits i)
        -inf.0)))

(: kept-id? (-> TokenId (Listof token-score) Boolean))
(define (kept-id? id kept)
  (cond
    [(null? kept) #f]
    [(= id (token-score-id (car kept))) #t]
    [else (kept-id? id (cdr kept))]))

(: dropped-softmax-mass (-> LogitVector (Listof token-score) Flonum))
(define (dropped-softmax-mass logits kept)
  (define max-logit (vector-max-logit logits))
  (cond
    [(eqv? max-logit -inf.0) 0.0]
    [else
     (define denominator (sum-exp-shifted logits max-logit #f kept))
     (cond
       [(zero? denominator) 0.0]
       [else
        (define dropped (sum-exp-shifted logits max-logit #t kept))
        (real->double-flonum (/ dropped denominator))])]))

(: vector-max-logit (-> LogitVector Flonum))
(define (vector-max-logit logits)
  (for/fold ([best : Flonum -inf.0])
            ([x (in-vector logits)])
    (max best x)))

(: sum-exp-shifted (-> LogitVector Flonum Boolean (Listof token-score) Flonum))
(define (sum-exp-shifted logits max-logit dropped-only? kept)
  (for/fold ([acc : Flonum 0.0])
            ([i (in-range (vector-length logits))])
    (define id (assert i exact-nonnegative-integer?))
    (define dropped? (not (kept-id? id kept)))
    (if (or (not dropped-only?) dropped?)
        (+ acc (exp (- (vector-ref logits i) max-logit)))
        acc)))

(: usable-logit? (-> Logit Boolean))
(define (usable-logit? x)
  (> x -1e300))

;; Small vocab helpers used by compatibility adapters. Unknown text is an error
;; because silently dropping bytes makes replay non-reproducible.

(: tokenize-vocab (-> (Listof String) String (Listof TokenId)))
(define (tokenize-vocab vocab text)
  (let loop ([pos : Natural 0])
    (cond
      [(= pos (string-length text)) '()]
      [else
       (define match (longest-token-at vocab text pos 0 #f))
       (cond
         [match (cons match
                      (loop (+ pos (string-length (list-ref vocab match)))))]
         [else
          (error 'tokenize-vocab
                 "no token in vocabulary matches input at offset ~a: ~s"
                 pos
                 text)])])))

(: longest-token-at
   (-> (Listof String) String Natural TokenId (Option TokenId) (Option TokenId)))
(define (longest-token-at vocab text pos id best)
  (cond
    [(null? vocab) best]
    [else
     (define token (car vocab))
     (define next-best
       (if (and (token-prefix-at? token text pos)
                (or (not best)
                    (> (string-length token)
                       (string-length (list-ref vocab best)))))
           id
           best))
     (longest-token-at (cdr vocab) text pos (add1 id) next-best)]))

(: token-prefix-at? (-> String String Natural Boolean))
(define (token-prefix-at? token text pos)
  (define end (+ pos (string-length token)))
  (and (<= end (string-length text))
       (string=? token (substring text pos end))))

(: detokenize-vocab (-> (Listof String) (Listof TokenId) String))
(define (detokenize-vocab vocab ids)
  (apply string-append
         (for/list : (Listof String) ([id (in-list ids)])
           (cond
             [(< id (length vocab)) (list-ref vocab id)]
             [else (error 'detokenize-vocab
                          "token id out of range: ~a"
                          id)]))))

(: candidates->logits (-> (Listof String) (Listof token-candidate) LogitVector))
(define (candidates->logits vocab candidates)
  (for/vector : LogitVector ([token (in-list vocab)])
    (candidate-logp token candidates)))

(: candidate-logp (-> String (Listof token-candidate) Logit))
(define (candidate-logp token candidates)
  (cond
    [(null? candidates) -inf.0]
    [(string=? token (token-candidate-text (car candidates)))
     (token-candidate-logp (car candidates))]
    [else (candidate-logp token (cdr candidates))]))
