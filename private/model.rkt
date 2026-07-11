#lang typed/racket/base

(require racket/list
         (only-in "logits.rkt" LogitsView check-logits-view))

(provide TokenId TokenIds Tokenizer Provider Model
         tokenizer tokenize detokenize token-ref vocab-size
         provider provider-vocab-size provider-eog-token-ids provider-start-session
         provider-next-logits provider-commit-token! provider-end-session!
         model model-tokenizer model-provider model-metadata model-close!
         model-acquire! model-release!)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))

(struct tokenizer-impl
  ([tokenize : (-> String TokenIds)]
   [detokenize : (-> TokenIds String)]
   [token-ref : (-> TokenId String)]
   [vocab-size : Natural])
  #:transparent)
(define-type Tokenizer tokenizer-impl)

(: tokenizer
   (-> #:tokenize (-> String TokenIds)
       #:detokenize (-> TokenIds String)
       #:token-ref (-> TokenId String)
       #:vocab-size Natural
       Tokenizer))
(define (tokenizer #:tokenize encode #:detokenize decode #:token-ref piece
                   #:vocab-size size)
  (tokenizer-impl
   (lambda ([text : String])
     (define ids (encode text))
     (check-ids 'tokenize ids size)
     ids)
   (lambda ([ids : TokenIds]) (check-ids 'detokenize ids size) (decode ids))
   (lambda ([id : TokenId])
     (unless (< id size) (raise-argument-error 'token-ref (format "token id < ~a" size) id))
     (piece id))
   size))

(: tokenize (-> Tokenizer String TokenIds))
(define (tokenize t text) ((tokenizer-impl-tokenize t) text))
(: detokenize (-> Tokenizer TokenIds String))
(define (detokenize t ids) ((tokenizer-impl-detokenize t) ids))
(: token-ref (-> Tokenizer TokenId String))
(define (token-ref t id) ((tokenizer-impl-token-ref t) id))
(: vocab-size (-> Tokenizer Natural))
(define (vocab-size t) (tokenizer-impl-vocab-size t))

(: check-ids (-> Symbol TokenIds Natural Void))
(define (check-ids who ids size)
  (for ([id (in-list ids)])
    (unless (< id size) (raise-argument-error who (format "token id < ~a" size) id))))

(struct provider-impl
  ([vocab-size : Natural]
   [eog-token-ids : TokenIds]
   [start : (-> TokenIds Any)]
   [logits : (-> Any LogitsView)]
   [commit : (-> Any TokenId Void)]
   [end : (-> Any Void)])
  #:transparent)
(define-type Provider provider-impl)

(: provider
   (-> #:vocab-size Natural
       #:eog-token-ids TokenIds
       #:start-session (-> TokenIds Any)
       #:next-logits/session (-> Any LogitsView)
       #:commit-token! (-> Any TokenId Void)
       #:end-session! (-> Any Void)
       Provider))
(define (provider #:vocab-size size #:eog-token-ids eog-token-ids #:start-session start
                  #:next-logits/session logits #:commit-token! commit #:end-session! end)
  (check-ids 'provider eog-token-ids size)
  (when (null? eog-token-ids)
    (raise-argument-error 'provider "non-empty list of EOG token ids" eog-token-ids))
  (unless (= (length eog-token-ids) (length (remove-duplicates eog-token-ids)))
    (raise-argument-error 'provider "distinct EOG token ids" eog-token-ids))
  (provider-impl size eog-token-ids start logits commit end))

(: provider-vocab-size (-> Provider Natural))
(define (provider-vocab-size p) (provider-impl-vocab-size p))
(: provider-eog-token-ids (-> Provider TokenIds))
(define (provider-eog-token-ids p) (provider-impl-eog-token-ids p))
(: provider-start-session (-> Provider TokenIds Any))
(define (provider-start-session p ids) ((provider-impl-start p) ids))
(: provider-next-logits (-> Provider Any LogitsView))
(define (provider-next-logits p session)
  (define logits ((provider-impl-logits p) session))
  (check-logits-view 'provider-next-logits logits (provider-vocab-size p))
  logits)
(: provider-commit-token! (-> Provider Any TokenId Void))
(define (provider-commit-token! p session id) ((provider-impl-commit p) session id))
(: provider-end-session! (-> Provider Any Void))
(define (provider-end-session! p session) ((provider-impl-end p) session))

(struct model-impl
  ([tokenizer : Tokenizer]
   [provider : Provider]
   [metadata : (HashTable Symbol Any)]
   [close-proc : (-> Void)]
   [closed? : (Boxof Boolean)]
   [leases : (Boxof Natural)])
  #:transparent)
(define-type Model model-impl)

(: model (-> Tokenizer Provider (HashTable Symbol Any) (-> Void) Model))
(define (model tok p metadata close!) (model-impl tok p metadata close! (box #f) (box 0)))

(: model-acquire! (-> Model Void))
(define (model-acquire! m)
  (when (unbox (model-impl-closed? m))
    (error 'make-generator "model is closed"))
  (set-box! (model-impl-leases m) (add1 (unbox (model-impl-leases m)))))

(: model-release! (-> Model Void))
(define (model-release! m)
  (define leases (unbox (model-impl-leases m)))
  (when (zero? leases)
    (error 'generator-close! "model lease is already released"))
  (set-box! (model-impl-leases m) (sub1 leases)))

(: model-tokenizer (-> Model Tokenizer))
(define (model-tokenizer m) (model-impl-tokenizer m))
(: model-provider (-> Model Provider))
(define (model-provider m) (model-impl-provider m))
(: model-metadata (-> Model (HashTable Symbol Any)))
(define (model-metadata m) (model-impl-metadata m))

(: model-close! (-> Model Void))
(define (model-close! m)
  (unless (unbox (model-impl-closed? m))
    (unless (zero? (unbox (model-impl-leases m)))
      (error 'model-close! "model has active generators"))
    (set-box! (model-impl-closed? m) #t)
    ((model-impl-close-proc m))))
