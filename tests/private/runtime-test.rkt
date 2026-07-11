#lang racket/base

(require racket/list
         racket/sandbox
         rackunit
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
       #:eog-token-ids '(0)
       #:start-session (lambda (_prompt-ids) 'session)
       #:next-logits/session (lambda (_session) (vector->logits-view logits))
       #:commit-token! (lambda (_session _token-id) (void))
       #:end-session! (lambda (_session) (void))))
    (define m (model tok p (hash 'name 'large-mock) void))
    (collect-garbage)
    (define result
      (generate m
                ""
                (lit " target")
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
       #:eog-token-ids '(0)
       #:start-session
       (lambda (_prompt-ids) 'session)
       #:next-logits/session
       (lambda (_session)
         (set! logits-calls (add1 logits-calls))
         (vector->logits-view (vector 0.0 0.0 0.0 0.0 0.0)))
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
                #:max-tokens 8
                #:seed 0))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (generation-result-text result) " A B C D")
    (check-equal? logits-calls 0)
    (check-equal? commits '(1 2 3 4))
    (check-false (generation-result-lm-logprob result))
    (check-equal? (generation-metrics-llm-calls (generation-result-metrics result)) 0)
    (check-equal?
     (generation-metrics-candidate-count-per-step (generation-result-metrics result))
     '(1)))

  (test-case "broad bounded regex full-vocab step does not spend time in epsilon closure"
    (define vocab-size 50000)
    (define tok
      (tokenizer
       #:vocab-size vocab-size
       #:token-ref
       (lambda (id)
         (cond
           [(= id 0) "My"]
           [(= id 1) " Answer:"]
           [(= id 2) " x"]
           [else " filler"]))
       #:tokenize
       (lambda (_text) '())
       #:detokenize
       (lambda (ids)
         (apply string-append
                (map (lambda (id)
                       (cond
                         [(= id 0) "My"]
                         [(= id 1) " Answer:"]
                         [(= id 2) " x"]
                         [else " filler"]))
                     ids)))))
    (define logits (make-vector vocab-size 0.0))
    (define p
      (provider
       #:vocab-size vocab-size
       #:eog-token-ids '(0)
       #:start-session (lambda (_prompt-ids) 'session)
       #:next-logits/session (lambda (_session) (vector->logits-view logits))
       #:commit-token! (lambda (_session _token-id) (void))
       #:end-session! (lambda (_session) (void))))
    (define m (model tok p (hash 'name 'large-regex-mock) void))
    (define result
      (call-with-limits
       2
       256
       (lambda ()
         (generate m
                   ""
                   (rx "My Answer: .{1,512} My Conclusion: .{1,512} Future Outlook: .{1,512}")
                   #:max-tokens 1
                   #:seed 0))))
    (check-not-false
     (member (generation-result-status result) '(found not-found-budget not-found-hard))))

  (test-case "broad bounded regex full-vocab avoids per-candidate filter state allocation"
    (define vocab-size 100000)
    (define (token-text id)
      (cond
        [(= id 0) "My"]
        [(= id 1) " Answer:"]
        [(= id 2) " x"]
        [(= id 3) " My"]
        [(= id 4) " Conclusion:"]
        [(= id 5) " y"]
        [(= id 6) " Future"]
        [(= id 7) " Outlook:"]
        [(= id 8) " z"]
        [else " filler"]))
    (define tok
      (tokenizer
       #:vocab-size vocab-size
       #:token-ref token-text
       #:tokenize (lambda (_text) '())
       #:detokenize (lambda (ids) (apply string-append (map token-text ids)))))
    (define logits (make-vector vocab-size 0.0))
    (define p
      (provider
       #:vocab-size vocab-size
       #:eog-token-ids '(0)
       #:start-session (lambda (_prompt-ids) 'session)
       #:next-logits/session (lambda (_session) (vector->logits-view logits))
       #:commit-token! (lambda (_session _token-id) (void))
       #:end-session! (lambda (_session) (void))))
    (define m (model tok p (hash 'name 'large-regex-fast-path-mock) void))
    (define result
      (call-with-limits
       2
       256
       (lambda ()
         (generate m
                   ""
                   (rx "My Answer: .{1,512} My Conclusion: .{1,512} Future Outlook: .{1,512}")
                   #:max-tokens 4
                   #:seed 0))))
    (check-not-false
     (member (generation-result-status result) '(found not-found-budget not-found-hard)))
    (check-true
     (andmap (lambda (count) (<= count vocab-size))
             (generation-metrics-candidate-count-per-step (generation-result-metrics result)))))

  (test-case "budget-feasible template completes even when logits maximize every wildcard"
    (define pattern
      "My Answer: [^~]{1,24} My Conclusion: [^~]{1,24} Future Outlook: [^~]{1,24}~END")
    (define chars
      (remove-duplicates
       (map string (string->list (string-append pattern "x")))))
    (define vocab (cons "" chars))
    (define tok (simple-tokenizer vocab))
    (define logits
      (for/vector ([piece (in-list vocab)])
        (if (string=? piece "x") 0.0 -1000.0)))
    (define p
      (provider
       #:vocab-size (length vocab)
       #:eog-token-ids '(0)
       #:start-session (lambda (_prompt-ids) 'session)
       #:next-logits/session (lambda (_session) (vector->logits-view logits))
       #:commit-token! (lambda (_session _token-id) (void))
       #:end-session! (lambda (_session) (void))))
    (define m (model tok p (hash 'name 'template-budget) void))
    (define result
      (generate m "" (rx pattern) #:max-tokens 128 #:seed 0))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (generation-result-generated-tokens result) 120)
    (check-regexp-match
     #px"^My Answer: [^~]{1,24} My Conclusion: [^~]{1,24} Future Outlook: [^~]{1,24}~END$"
     (generation-result-text result)))

  (test-case "live broad regex reports token budget exhaustion honestly"
    (define pattern "A [^~]{1,512}~END")
    (define tok (simple-tokenizer '("" "A" " " "x" "~" "E" "N" "D")))
    (define logits (vector -1000.0 -1000.0 -1000.0 0.0 -1000.0 -1000.0 -1000.0 -1000.0))
    (define p
      (provider
       #:vocab-size 8
       #:eog-token-ids '(0)
       #:start-session (lambda (_prompt-ids) 'session)
       #:next-logits/session (lambda (_session) (vector->logits-view logits))
       #:commit-token! (lambda (_session _token-id) (void))
       #:end-session! (lambda (_session) (void))))
    (define m (model tok p (hash 'name 'broad-budget) void))
    (define result
      (generate m "" (rx pattern) #:max-tokens 128 #:seed 0))
    (check-equal? (generation-result-status result) 'not-found-budget)
    (check-equal? (generation-result-generated-tokens result) 128))
