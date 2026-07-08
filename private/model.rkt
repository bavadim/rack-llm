#lang typed/racket/base

(require (only-in "logits.rkt"
                  LogitsView
                  check-logits-view))

(provide TokenId
         TokenIds
         ProviderMode
         Tokenizer
         Provider
         Model
         tokenizer
         tokenize
         detokenize
         token-ref
         vocab-size
         fingerprint
         provider
         provider-next-logits
         provider-session-supported?
         provider-vocab-size
         provider-mode
         provider-metadata
         provider-start-session
         provider-next-logits/session
         provider-commit-token!
         provider-end-session!
         model
         model-tokenizer
         model-provider
         model-metadata
         model-close!)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))
(define-type ProviderMode (U 'exact-full-vocab 'top-k-approx))

(struct tokenizer-impl
  ([tokenize-proc : (-> String TokenIds)]
   [detokenize-proc : (-> TokenIds String)]
   [token-ref-proc : (-> TokenId String)]
   [vocab-size : Natural]
   [fingerprint : String])
  #:transparent)
(define-type Tokenizer tokenizer-impl)

(: tokenizer
   (-> #:tokenize (-> String TokenIds)
       #:detokenize (-> TokenIds String)
       #:token-ref (-> TokenId String)
       #:vocab-size Natural
       #:fingerprint String
       Tokenizer))
(define (tokenizer #:tokenize tokenize-proc
                   #:detokenize detokenize-proc
                   #:token-ref token-ref-proc
                   #:vocab-size size
                   #:fingerprint fp)
  (tokenizer-impl
   (lambda ([text : String])
     (define ids (tokenize-proc text))
     (check-token-ids 'tokenize ids size)
     ids)
   (lambda ([ids : TokenIds])
     (check-token-ids 'detokenize ids size)
     (detokenize-proc ids))
   (lambda ([id : TokenId])
     (unless (< id size)
       (raise-argument-error 'token-ref (format "token id < ~a" size) id))
     (token-ref-proc id))
   size
   fp))

(: tokenize (-> Tokenizer String TokenIds))
(define (tokenize tok text)
  ((tokenizer-impl-tokenize-proc tok) text))

(: detokenize (-> Tokenizer TokenIds String))
(define (detokenize tok ids)
  ((tokenizer-impl-detokenize-proc tok) ids))

(: token-ref (-> Tokenizer TokenId String))
(define (token-ref tok id)
  ((tokenizer-impl-token-ref-proc tok) id))

(: vocab-size (-> Tokenizer Natural))
(define (vocab-size tok)
  (tokenizer-impl-vocab-size tok))

(: fingerprint (-> Tokenizer String))
(define (fingerprint tok)
  (tokenizer-impl-fingerprint tok))

(: check-token-ids (-> Symbol TokenIds Natural Void))
(define (check-token-ids who ids size)
  (for ([id (in-list ids)])
    (unless (< id size)
      (raise-argument-error who (format "token id < ~a" size) id))))

(struct provider-impl
  ([vocab-size : Natural]
   [next-logits : (-> TokenIds TokenIds LogitsView)]
   [mode : ProviderMode]
   [metadata : (HashTable Symbol Any)]
   [start-session : (Option (-> TokenIds Any))]
   [next-logits/session : (Option (-> Any LogitsView))]
   [commit-token! : (Option (-> Any TokenId Void))]
   [end-session! : (Option (-> Any Void))])
  #:transparent)
(define-type Provider provider-impl)

(: provider
   (->* (#:vocab-size Natural
         #:next-logits (-> TokenIds TokenIds LogitsView))
        (#:mode ProviderMode
         #:metadata (HashTable Symbol Any)
         #:start-session (Option (-> TokenIds Any))
         #:next-logits/session (Option (-> Any LogitsView))
         #:commit-token! (Option (-> Any TokenId Void))
         #:end-session! (Option (-> Any Void)))
        Provider))
(define (provider #:vocab-size size
                  #:next-logits next-logits-proc
                  #:mode [mode 'exact-full-vocab]
                  #:metadata [metadata (ann (hash) (HashTable Symbol Any))]
                  #:start-session [start-session #f]
                  #:next-logits/session [next-logits/session #f]
                  #:commit-token! [commit-token! #f]
                  #:end-session! [end-session! #f])
  (when (or start-session next-logits/session commit-token! end-session!)
    (unless (and start-session next-logits/session commit-token! end-session!)
      (raise-arguments-error 'provider
                             "session protocol requires all four session callbacks")))
  (provider-impl size next-logits-proc mode metadata
                 start-session next-logits/session commit-token! end-session!))

(: provider-next-logits (-> Provider TokenIds TokenIds LogitsView))
(define (provider-next-logits p prompt-ids prefix-ids)
  (define logits ((provider-impl-next-logits p) prompt-ids prefix-ids))
  (check-logits-view 'provider-next-logits logits (provider-impl-vocab-size p))
  logits)

(: provider-session-supported? (-> Provider Boolean))
(define (provider-session-supported? p)
  (and (provider-impl-start-session p)
       (provider-impl-next-logits/session p)
       (provider-impl-commit-token! p)
       (provider-impl-end-session! p)
       #t))

(: provider-vocab-size (-> Provider Natural))
(define (provider-vocab-size p) (provider-impl-vocab-size p))

(: provider-mode (-> Provider ProviderMode))
(define (provider-mode p) (provider-impl-mode p))

(: provider-metadata (-> Provider (HashTable Symbol Any)))
(define (provider-metadata p) (provider-impl-metadata p))

(: provider-start-session (-> Provider (Option (-> TokenIds Any))))
(define (provider-start-session p) (provider-impl-start-session p))

(: provider-next-logits/session (-> Provider (Option (-> Any LogitsView))))
(define (provider-next-logits/session p) (provider-impl-next-logits/session p))

(: provider-commit-token! (-> Provider (Option (-> Any TokenId Void))))
(define (provider-commit-token! p) (provider-impl-commit-token! p))

(: provider-end-session! (-> Provider (Option (-> Any Void))))
(define (provider-end-session! p) (provider-impl-end-session! p))

(struct model
  ([tokenizer : Tokenizer]
   [provider : Provider]
   [metadata : (HashTable Symbol Any)]
   [close! : (-> Void)])
  #:transparent)
(define-type Model model)
