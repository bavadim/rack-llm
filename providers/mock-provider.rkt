#lang typed/racket/base

(require "../grammar.rkt"
         "provider-v2.rkt")

(provide make-mock-provider)

(: make-mock-provider
   (->* (#:vocab (Listof String)
         #:default-logits LogitVector)
        (#:prefix-logits (HashTable String LogitVector)
         #:model-id String
         #:model-hash (Option String))
        Provider))
(define (make-mock-provider #:vocab vocab
                            #:default-logits default-logits
                            #:prefix-logits [prefix-logits (ann (hash) (HashTable String LogitVector))]
                            #:model-id [model-id "mock"]
                            #:model-hash [model-hash #f])
  (define vocab-size (length vocab))
  (check-logit-vector 'default-logits default-logits vocab-size)
  (for ([prefix (in-hash-keys prefix-logits)])
    (check-logit-vector prefix (hash-ref prefix-logits prefix) vocab-size))
  (provider
   (make-provider-info 'mock 'exact-full-vocab model-id model-hash vocab-size)
   (provider-state 'mock)
   (lambda ([text : String]) (tokenize-vocab vocab text))
   (lambda ([ids : (Listof TokenId)]) (detokenize-vocab vocab ids))
   (lambda ([_transcript : EvaluatedProgram] [prefix : String] [state : ProviderState])
     (define logits
       (hash-ref prefix-logits prefix (lambda () default-logits)))
     (logits-result logits
                    state
                    (provider-trace 0
                                    (length (tokenize-vocab vocab prefix))
                                    #f
                                    0.0
                                    #f)))))

(: check-logit-vector (-> Any LogitVector Natural Void))
(define (check-logit-vector label logits expected-length)
  (unless (= (vector-length logits) expected-length)
    (error 'make-mock-provider
           "~a has length ~a, expected vocabulary length ~a"
           label
           (vector-length logits)
           expected-length)))

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
          (error 'mock-tokenize
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
             [else (error 'mock-detokenize
                          "token id out of range: ~a"
                          id)]))))
