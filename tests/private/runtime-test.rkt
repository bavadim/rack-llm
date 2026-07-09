#lang racket/base

(require rackunit
         "../../main.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt")

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
  (test-case "allowed-only literal generation does not scale with full vocab candidates"
    (define vocab-size 1000000)
    (define target-id (sub1 vocab-size))
    (define tok
      (tokenizer
       #:vocab-size vocab-size
       #:fingerprint "large-mock"
       #:token-ref (lambda (id) (if (= id target-id) " target" " filler"))
       #:tokenize
       (lambda (text)
         (cond
           [(equal? text "") '()]
           [(equal? text " target") (list target-id)]
           [else (error 'large-mock-tokenize "unexpected text: ~s" text)]))
       #:detokenize
       (lambda (ids)
         (if (equal? ids (list target-id)) " target" ""))))
    (define logits (make-vector vocab-size -1000.0))
    (vector-set! logits target-id 0.0)
    (define p
      (provider
       #:vocab-size vocab-size
       #:next-logits (lambda (_prompt-ids _prefix-ids)
                       (vector->logits-view logits))))
    (define m (model tok p (hash 'name 'large-mock) void))
    (collect-garbage)
    (define result
      (generate m
                ""
                (lit " target")
                #:candidate-policy 'allowed-only
                #:max-tokens 1
                #:seed 0))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (generation-result-token-ids result) (list target-id))
    (check-equal? (generation-result-text result) " target")
    (check-equal?
     (generation-metrics-candidate-count-per-step (generation-result-metrics result))
     '(1))
    (check-true
     (<= (generation-result-latency-ms result) 100.0)
     (format "allowed-only single-token literal took ~a ms"
             (generation-result-latency-ms result)))))

  (test-case "deterministic literal fast-forwards without logits calls"
    (define tok
      (simple-tokenizer '("" " A" " B" " C" " D")))
    (define logits-calls 0)
    (define commits '())
    (define p
      (provider
       #:vocab-size 5
       #:next-logits
       (lambda (_prompt-ids _prefix-ids)
         (set! logits-calls (add1 logits-calls))
         (error 'runtime-test "non-session logits should not be requested"))
       #:start-session
       (lambda (_prompt-ids) 'session)
       #:next-logits/session
       (lambda (_session)
         (set! logits-calls (add1 logits-calls))
         (error 'runtime-test "session logits should not be requested"))
       #:commit-token!
       (lambda (_session token-id)
         (set! commits (append commits (list token-id))))
       #:end-session!
       void))
    (define m (model tok p (hash 'name 'forced-literal) void))
    (define result
      (generate m
                ""
                (lit " A B C D")
                #:candidate-policy 'allowed-only
                #:max-tokens 8
                #:seed 0))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (generation-result-text result) " A B C D")
    (check-equal? logits-calls 0)
    (check-equal? commits '(1 2 3 4))
    (check-equal? (generation-result-lm-logprob result) 0.0)
    (check-equal? (generation-metrics-llm-calls (generation-result-metrics result)) 0)
    (check-equal?
     (generation-metrics-candidate-count-per-step (generation-result-metrics result))
     '(1 1 1 1)))
