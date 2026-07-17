#lang racket/base

(require racket/list)
(provide tokenizer tokenize detokenize token-ref vocab-size tokenizer-fingerprint
         check-token-ids (struct-out factor-request) (struct-out factor-selection) make-rng
         provider provider-vocab-size provider-eog-token-ids provider-cohort-width
         provider-context-limit provider-open-cohort provider-restore-lanes!
         provider-sample-factors provider-decode! provider-close-cohort!
         model model-tokenizer model-provider model-close!
         model-ensure-open! model-enter-generation! model-leave-generation!)

(define (ids-ok? ids size)
  (and (list? ids) (andmap (lambda (id) (and (exact-nonnegative-integer? id) (< id size))) ids)))
(define (check-ids who ids size)
  (unless (ids-ok? ids size) (raise-argument-error who (format "token ids below ~a" size) ids)))

(struct tokenizer* (encode decode piece size fingerprint) #:transparent)
(define (tokenizer #:tokenize encode #:detokenize decode #:token-ref piece
                   #:vocab-size size #:fingerprint fingerprint)
  (unless (exact-positive-integer? size) (raise-argument-error 'tokenizer "positive vocab size" size))
  (unless (and (string? fingerprint) (not (string=? fingerprint "")))
    (raise-argument-error 'tokenizer "non-empty fingerprint string" fingerprint))
  (tokenizer* encode decode piece size fingerprint))
(define (check-token-ids who t ids) (check-ids who ids (vocab-size t)))
(define (tokenize t text)
  (define ids ((tokenizer*-encode t) text)) (check-ids 'tokenize ids (vocab-size t)) ids)
(define (detokenize t ids) (check-ids 'detokenize ids (vocab-size t)) ((tokenizer*-decode t) ids))
(define (token-ref t id) (check-ids 'token-ref (list id) (vocab-size t)) ((tokenizer*-piece t) id))
(define (vocab-size t) (tokenizer*-size t))
(define (tokenizer-fingerprint t) (tokenizer*-fingerprint t))

(struct factor-request (temperature domain constrain? children draw) #:transparent)
(struct factor-selection (id base-logprob base-probability frontier-mass) #:transparent)
(define (make-rng seed)
  (define rng (make-pseudo-random-generator))
  (when seed (parameterize ([current-pseudo-random-generator rng]) (random-seed (add1 (abs seed))))) rng)

(struct provider* (size eog width context open restore sample decode close) #:transparent)
(define (provider #:vocab-size size #:eog-token-ids eog #:cohort-width width
                  #:context-limit [context #f] #:open-cohort open
                  #:restore-lanes! restore #:sample-factors sample #:decode! decode
                  #:close-cohort! close)
  (unless (and (ids-ok? eog size) (pair? eog) (= (length eog) (length (remove-duplicates eog))))
    (raise-argument-error 'provider "distinct non-empty EOG ids" eog))
  (unless (exact-positive-integer? width) (raise-argument-error 'provider "positive cohort width" width))
  (provider* size eog width context open restore sample decode close))
(define (provider-vocab-size p) (provider*-size p))
(define (provider-eog-token-ids p) (provider*-eog p))
(define (provider-cohort-width p) (provider*-width p))
(define (provider-context-limit p) (provider*-context p))
(define (lanes! who p lanes)
  (unless (and (ids-ok? lanes (provider-cohort-width p))
               (= (length lanes) (length (remove-duplicates lanes))))
    (raise-argument-error who "distinct cohort lanes" lanes)))
(define (provider-open-cohort p prompts)
  (unless (= (length prompts) (provider-cohort-width p)) (error 'provider-open-cohort "cohort must be full"))
  (for ([ids prompts]) (check-ids 'provider-open-cohort ids (provider-vocab-size p)))
  ((provider*-open p) prompts))
(define (provider-restore-lanes! p cohort lanes)
  (lanes! 'provider-restore-lanes! p lanes) (unless (null? lanes) ((provider*-restore p) cohort lanes)))
(define (provider-sample-factors p cohort entries)
  (lanes! 'provider-sample-factors p (map car entries))
  (unless (andmap factor-request? (map cdr entries)) (raise-argument-error 'provider-sample-factors "factor requests" entries))
  (define values ((provider*-sample p) cohort entries))
  (unless (= (length values) (length entries)) (error 'provider-sample-factors "wrong result count")) values)
(define (provider-decode! p cohort tokens)
  (unless (= (length tokens) (provider-cohort-width p)) (error 'provider-decode! "decode batch must be full"))
  (check-ids 'provider-decode! tokens (provider-vocab-size p)) ((provider*-decode p) cohort tokens))
(define (provider-close-cohort! p cohort [poisoned? #f]) ((provider*-close p) cohort poisoned?))

(struct model* (tokenizer provider close closed busy) #:transparent)
(define (model tok provider close) (model* tok provider close (box #f) (box #f)))
(define (model-tokenizer m) (model*-tokenizer m))
(define (model-provider m) (model*-provider m))
(define (model-ensure-open! who m) (when (unbox (model*-closed m)) (error who "model is closed")))
(define (model-enter-generation! m)
  (model-ensure-open! 'generate-batch m)
  (when (unbox (model*-busy m)) (error 'generate-batch "model-busy: generation is not reentrant"))
  (set-box! (model*-busy m) #t))
(define (model-leave-generation! m) (set-box! (model*-busy m) #f))
(define (model-close! m)
  (unless (unbox (model*-closed m))
    (when (unbox (model*-busy m)) (error 'model-close! "model is generating"))
    ((model*-close m)) (set-box! (model*-closed m) #t)))
