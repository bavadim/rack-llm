#lang racket/base

(require rackunit
         racket/list
         racket/string
         rack-llm
         rack-llm/private/logits
         rack-llm/private/model
         (prefix-in choice: "../examples/hard-choice.rkt")
         (prefix-in ban: "../examples/hard-ban-batch.rkt")
         (prefix-in soft: "../examples/soft-pwsg.rkt"))

(define pieces
  (vector " yes"
          " no"
          " status=approved"
          " status=rejected"
          " status=TODO"
          " clear"
          " answer"
          " sorry"
          " unknown"
          " filler"
          "<eog>"))

(define prompts
  '("Reply with exactly yes or no:"
    "Return one status: approved or rejected."
    "Give a short direct answer to: What is 2+2?"))

(define (encode source)
  (cond
    [(or (string=? source "") (member source prompts)) '()]
    [else
     (let loop ([remaining source])
       (cond
         [(string=? remaining "") '()]
         [else
          (define found
            (for/first ([piece (in-vector pieces)]
                        [id (in-naturals)]
                        #:unless (= id 10)
                        #:when (string-prefix? remaining piece))
              (cons id piece)))
          (unless found (error 'example-tokenize "unknown text ~s" source))
          (cons (car found)
                (loop (substring remaining (string-length (cdr found)))))]))]))

(define tokenizer*
  (tokenizer
   #:vocab-size (vector-length pieces)
   #:token-ref (lambda (id) (vector-ref pieces id))
   #:tokenize encode
   #:detokenize
   (lambda (ids)
     (apply string-append
            (map (lambda (id) (vector-ref pieces id)) ids)))))

(define first-logits
  (vector 2.0 1.5 2.0 1.5 3.0 2.0 1.8 1.2 1.0 0.0 -3.0))
(define continuation-logits
  (vector -2.0 -2.0 -2.0 -2.0 -2.0 -2.0 -2.0 -2.0 -2.0 -2.0 4.0))

(define sessions (make-hash))
(define next-session-id (box 0))

(define provider*
  (provider
   #:vocab-size (vector-length pieces)
   #:eog-token-ids '(10)
   #:start-session
   (lambda (_prompt-ids)
     (define id (unbox next-session-id))
     (set-box! next-session-id (add1 id))
     (hash-set! sessions id 0)
     id)
   #:next-logits/session
   (lambda (session)
     (vector->logits-view
      (if (zero? (hash-ref sessions session)) first-logits continuation-logits)))
   #:commit-token!
   (lambda (session _id)
     (hash-set! sessions session (add1 (hash-ref sessions session))))
   #:end-session! (lambda (session) (hash-remove! sessions session))))

(module+ test
  (define model* (model tokenizer* provider* (hash 'name 'examples-mock) void))
  (dynamic-wind
    void
    (lambda ()
      (test-case "hard choice example uses the exact hard distribution"
        (define result (choice:run-example model*))
        (check-equal? (generation-result-status result) 'found)
        (check-not-false (member (generation-result-text result) '(" yes" " no")))
        (check-equal? (generation-result-distribution-guarantee result) 'exact-hard))

      (test-case "hard ban batch reuses a generator without admitting TODO"
        (define results (ban:run-example model*))
        (check-equal? (length results) 3)
        (for ([result (in-list results)])
          (check-equal? (generation-result-status result) 'found)
          (check-false (string-contains? (generation-result-text result) "TODO"))
          (check-equal? (generation-result-distribution-guarantee result) 'exact-hard)))

      (test-case "soft example fits and applies a weak model"
        (define result (soft:run-example model*))
        (check-equal? (generation-result-status result) 'found)
        (check-true (weak-result? (generation-result-weak result)))
        (check-equal? (generation-result-distribution-guarantee result) 'exact-pwsg)
        (check-true
         (> (generation-metrics-weak-evaluations
             (generation-result-metrics result))
            0))))
    (lambda () (model-close! model*))))
