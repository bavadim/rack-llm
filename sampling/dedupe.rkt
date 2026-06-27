#lang racket/base

(provide (struct-out dedupe-candidate)
         make-dedupe-filter)

(struct dedupe-candidate
  (text
   tokens
   object)
  #:transparent)

(define (make-dedupe-filter modes object-keyer)
  (define seen-tokens (make-hash))
  (define seen-strings (make-hash))
  (define seen-objects (make-hash))
  (lambda (candidate)
    (define duplicate?
      (for/or ([mode (in-list modes)])
        (case mode
          [(tokens)
           (seen-key? seen-tokens (tokens-key candidate))]
          [(string)
           (seen-key? seen-strings (string-key candidate))]
          [(object)
           (define maybe-key
             (and object-keyer (object-keyer candidate)))
           (and maybe-key (seen-key? seen-objects maybe-key))]
          [else (error 'make-dedupe-filter
                       "unsupported dedupe mode: ~a"
                       mode)])))
    (cond
      [duplicate? #f]
      [else
       (for ([mode (in-list modes)])
         (case mode
           [(tokens) (hash-set! seen-tokens (tokens-key candidate) #t)]
           [(string) (hash-set! seen-strings (string-key candidate) #t)]
           [(object)
            (define maybe-key
              (and object-keyer (object-keyer candidate)))
            (when maybe-key
              (hash-set! seen-objects maybe-key #t))]
           [else (void)]))
       #t])))

(define (seen-key? table key)
  (hash-ref table key #f))

(define (tokens-key candidate)
  (cond
    [(dedupe-candidate? candidate)
     (format "~s" (dedupe-candidate-tokens candidate))]
    [else (format "~s" candidate)]))

(define (string-key candidate)
  (cond
    [(dedupe-candidate? candidate) (dedupe-candidate-text candidate)]
    [(string? candidate) candidate]
    [else (format "~a" candidate)]))
