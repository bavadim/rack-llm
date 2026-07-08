#lang racket/base

(require racket/list
         racket/runtime-path
         racket/string
         rackunit
         "../main.rkt")

(define-runtime-path core-module "../main.rkt")
(define-runtime-path qwen-module "../model-qwen.rkt")

(define (exported-value module-path name)
  (with-handlers ([exn:fail? (lambda (_exn) 'missing)])
    (dynamic-require module-path name (lambda () 'missing))))

(define (simple-tokenizer vocab)
  (define vocab-vector (list->vector vocab))
  (define (longest-at text pos)
    (for/fold ([best #f]) ([id (in-range (vector-length vocab-vector))])
      (define token (vector-ref vocab-vector id))
      (define end (+ pos (string-length token)))
      (define matches?
        (and (<= end (string-length text))
             (string=? token (substring text pos end))))
      (if (and matches?
               (or (not best)
                   (> (string-length token)
                      (string-length (vector-ref vocab-vector best)))))
          id
          best)))
  (tokenizer
   #:vocab-size (vector-length vocab-vector)
   #:fingerprint (format "test:~a" (length vocab))
   #:token-ref (lambda (id) (vector-ref vocab-vector id))
   #:tokenize
   (lambda (text)
     (let loop ([pos 0])
       (cond
         [(= pos (string-length text)) '()]
         [else
          (define id (longest-at text pos))
          (unless id (error 'simple-tokenizer "no token at offset ~a in ~s" pos text))
          (cons id (loop (+ pos (string-length (vector-ref vocab-vector id)))))])))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref vocab-vector id)) ids)))))

(module+ test
  (test-case "public API exports the new token-native surface only"
    (for ([name (in-list '(tokenizer
                           provider
                           model
                           tokenize
                           detokenize
                           token-ref
                           vocab-size
                           fingerprint
                           provider-next-logits
                           provider-session-supported?
                           provider-vocab-size
                           provider-mode
                           provider-metadata
                           model-tokenizer
                           model-provider
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
                           generate
                           generation-metrics-filter-step-calls))])
      (check-not-equal? (exported-value core-module name)
                        'missing
                        (format "~a should be exported" name)))

    (for ([name (in-list '(make-tokenizer
                           make-provider
                           make-mock-provider
                           mock-provider
                           make-lit-filter
                           make-rx-filter
                           make-pure-filter
                           make-seq-filter
                           make-choice-filter
                           make-repeat-filter
                           make-bind-filter
                           make-score-filter
                           make-text-filter
                           make-rank-watcher
                           make-ban-watcher
                           fit-weighted-watcher
                           check
                           check-result
                           generate-stream
                           found?
                           not-found?
                           hard-failure?
                           low-score?
                           provider-error?
                           generation-result-text
                           generation-result-guide-score
                           min-guide-score
                           min-total-score
                           score-filter
                           lit-filter
                           generation-metrics-runtime-step-calls
                           rx-machine
                           compile-regex-machine))])
      (check-equal? (exported-value core-module name)
                    'missing
                    (format "~a should not be exported" name)))

    (check-not-equal? (exported-value qwen-module 'qwen-model)
                      'missing)
    (check-equal? (exported-value qwen-module 'make-llama-cpp-backend)
                  'missing))

  (test-case "unsupported regex constructs fail at filter construction"
    (define tok (simple-tokenizer '("a" "1")))
    (check-exn #rx"unsupported backreference"
               (lambda () (rx tok "(a)\\1")))
    (check-exn #rx"unsupported regex group"
               (lambda () (rx tok "(?=a)a")))
    (check-exn #rx"unsupported regex anchor"
               (lambda () (rx tok "^a")))))
