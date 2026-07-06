#lang racket/base

(provide (struct-out provider)
         make-provider
         make-mock-provider
         provider-vocab-size
         provider-token-ref
         provider-vocab-vector
         provider-next-logit-vector
         provider-start-session
         provider-next-logits/session
         provider-commit-token!
         provider-end-session!
         provider-session-supported?
         tokenize
         detokenize)

(struct provider
  (vocab vocab-vector next-logits mode metadata tokenize detokenize
         start-session next-logits/session commit-token! end-session!)
  #:transparent)

(define provider-modes
  '(exact-full-vocab top-k-approx mock))

(define (make-provider #:vocab vocab
                       #:next-logits next-logits
                       #:mode [mode 'exact-full-vocab]
                       #:metadata [metadata (hash)]
                       #:tokenize [tokenize-proc #f]
                       #:detokenize [detokenize-proc #f]
                       #:start-session [start-session-proc #f]
                       #:next-logits/session [next-logits/session-proc #f]
                       #:commit-token! [commit-token-proc #f]
                       #:end-session! [end-session-proc #f])
  (unless (and (list? vocab) (andmap string? vocab))
    (raise-argument-error 'make-provider "list of strings" vocab))
  (unless (procedure? next-logits)
    (raise-argument-error 'make-provider "procedure?" next-logits))
  (when (and tokenize-proc (not (procedure? tokenize-proc)))
    (raise-argument-error 'make-provider "procedure? or #f" tokenize-proc))
  (when (and detokenize-proc (not (procedure? detokenize-proc)))
    (raise-argument-error 'make-provider "procedure? or #f" detokenize-proc))
  (for ([name (in-list '(start-session next-logits/session commit-token! end-session!))]
        [proc (in-list (list start-session-proc
                             next-logits/session-proc
                             commit-token-proc
                             end-session-proc))])
    (when (and proc (not (procedure? proc)))
      (raise-argument-error 'make-provider
                            (format "procedure? or #f for ~a" name)
                            proc)))
  (when (or start-session-proc next-logits/session-proc commit-token-proc end-session-proc)
    (unless (and start-session-proc
                 next-logits/session-proc
                 commit-token-proc
                 end-session-proc)
      (raise-arguments-error 'make-provider
                             "session protocol requires all four session callbacks")))
  (unless (memq mode provider-modes)
    (raise-argument-error 'make-provider
                          "(or/c 'exact-full-vocab 'top-k-approx 'mock)"
                          mode))
  (provider vocab
            (list->vector vocab)
            next-logits
            mode
            metadata
            tokenize-proc
            detokenize-proc
            start-session-proc
            next-logits/session-proc
            commit-token-proc
            end-session-proc))

(define (make-mock-provider #:vocab vocab
                            #:default-logits default-logits
                            #:prefix-logits [prefix-logits (hash)])
  (define vocab-size (length vocab))
  (check-logits 'default-logits default-logits vocab-size)
  (for ([prefix (in-hash-keys prefix-logits)])
    (check-logits prefix (hash-ref prefix-logits prefix) vocab-size))
  (make-provider
   #:vocab vocab
   #:mode 'mock
   #:metadata (hash 'name 'mock)
   #:next-logits (lambda (_prompt prefix)
                   (hash-ref prefix-logits prefix (lambda () default-logits)))))

(define (provider-next-logit-vector p prompt prefix)
  (define raw ((provider-next-logits p) prompt prefix))
  (case (provider-mode p)
    [(exact-full-vocab mock)
     (check-logits 'next-logits raw (provider-vocab-size p))
     raw]
    [(top-k-approx)
     (sparse-logits->vector raw (provider-vocab-size p))]
    [else
     (error 'provider-next-logit-vector
            "unsupported provider mode: ~a"
            (provider-mode p))]))

(define (provider-vocab-size p)
  (vector-length (provider-vocab-vector p)))

(define (provider-token-ref p id)
  (unless (and (exact-nonnegative-integer? id)
               (< id (provider-vocab-size p)))
    (raise-argument-error 'provider-token-ref
                          (format "token id < ~a" (provider-vocab-size p))
                          id))
  (vector-ref (provider-vocab-vector p) id))

(define (provider-session-supported? p)
  (and (provider-start-session p)
       (provider-next-logits/session p)
       (provider-commit-token! p)
       (provider-end-session! p)
       #t))

(define (check-logits label logits expected-length)
  (unless (and (vector? logits) (= (vector-length logits) expected-length))
    (raise-arguments-error label
                           "logits vector length must match vocabulary"
                           "expected" expected-length
                           "logits" logits)))

(define (sparse-logits->vector raw vocab-size)
  (cond
    [(vector? raw)
     (check-logits 'next-logits raw vocab-size)
     raw]
    [(hash? raw)
     (for/vector ([id (in-range vocab-size)])
       (define value (hash-ref raw id (lambda () -inf.0)))
       (unless (real? value)
         (error 'provider-next-logit-vector "logit is not numeric: ~s" value))
       value)]
    [(list? raw)
     (define logits (make-vector vocab-size -inf.0))
     (for ([entry (in-list raw)])
       (define-values (id value)
         (cond
           [(and (pair? entry) (exact-nonnegative-integer? (car entry)))
            (values (car entry) (cdr entry))]
           [(and (list? entry)
                 (= (length entry) 2)
                 (exact-nonnegative-integer? (car entry)))
            (values (car entry) (cadr entry))]
           [else
            (error 'provider-next-logit-vector
                   "top-k entry must be (cons token-id logit) or (list token-id logit): ~s"
                   entry)]))
       (unless (< id vocab-size)
         (error 'provider-next-logit-vector "token id out of range: ~a" id))
       (unless (real? value)
         (error 'provider-next-logit-vector "logit is not numeric: ~s" value))
       (vector-set! logits id value))
     logits]
    [else
     (error 'provider-next-logit-vector
            "top-k provider must return a vector, hash, or list of token logits: ~s"
            raw)]))

(define (tokenize p s)
  (define proc (provider-tokenize p))
  (define ids
    (if proc
        (proc s)
        (default-tokenize (provider-vocab-vector p) s)))
  (unless (and (list? ids)
               (andmap exact-nonnegative-integer? ids)
               (andmap (lambda (id) (< id (provider-vocab-size p))) ids))
    (error 'tokenize "provider tokenizer returned invalid token ids: ~s" ids))
  ids)

(define (default-tokenize vocab s)
  (let loop ([pos 0])
    (cond
      [(= pos (string-length s)) '()]
      [else
       (define id (longest-token-at vocab s pos 0 #f))
       (unless id
         (error 'tokenize "no token matches input at offset ~a: ~s" pos s))
       (cons id (loop (+ pos (string-length (vector-ref vocab id)))))])))

(define (longest-token-at vocab s pos id best)
  (cond
    [(= id (vector-length vocab)) best]
    [else
     (define token (vector-ref vocab id))
     (define end (+ pos (string-length token)))
     (define match?
       (and (<= end (string-length s))
            (string=? token (substring s pos end))))
     (longest-token-at
      vocab
      s
      pos
      (add1 id)
      (if (and match?
               (or (not best)
                   (> (string-length token)
                      (string-length (vector-ref vocab best)))))
          id
          best))]))

(define (detokenize p ids)
  (unless (and (list? ids)
               (andmap exact-nonnegative-integer? ids)
               (andmap (lambda (id) (< id (provider-vocab-size p))) ids))
    (error 'detokenize "invalid token ids: ~s" ids))
  (define proc (provider-detokenize p))
  (cond
    [(null? ids) ""]
    [(and proc (not (null? (cdr ids))))
      (let ([text (proc ids)])
        (unless (string? text)
          (error 'detokenize "provider detokenizer returned non-string: ~s" text))
        text)]
    [else
      (apply string-append
             (for/list ([id (in-list ids)])
               (provider-token-ref p id)))]))
