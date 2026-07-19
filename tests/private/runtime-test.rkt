#lang racket/base

(require rackunit
         "../../main.rkt"
         "../../backend.rkt"
         "../support/logits.rkt"
         "../support/fake-cohort.rkt")

(define pieces (vector " a" " b" " x" "<eog>"))
(define tokenizer*
  (make-tokenizer
   #:vocab-size 4
   #:fingerprint "runtime-test-v1"
   #:token-ref (lambda (id) (vector-ref pieces id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define id
              (for/first ([piece (in-vector pieces)] [i (in-naturals)]
                          #:when (string=? piece source)) i))
            (if id (list id) (error 'tokenize "unknown text ~s" source))]))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref pieces id)) ids)))))

(define decode-widths (box '()))
(define provider*
  (make-fake-cohort-provider
   #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 4
   #:start-lane (lambda (_prompt) (box 0))
   #:logits/lane (lambda (_session)
                   (vector->logits-view (vector 3.0 2.0 1.0 0.0)))
   #:commit-lane! (lambda (session _id) (set-box! session (add1 (unbox session))))
   #:on-decode-width
   (lambda (width) (set-box! decode-widths (cons width (unbox decode-widths))))))
(define model* (make-backend tokenizer* provider* void))

(define (request compiled seed #:attempts [attempts 8] #:max-tokens [max-tokens 1])
  (generation-request
   compiled "" #:max-attempts attempts
   #:temperature 1.0 #:max-tokens max-tokens #:seed seed))

(module+ test
  (test-case "hard CARS returns only the finite hard language"
    (define compiled (compile-spec model* (choice (lit " a") (lit " b"))))
    (define result (generate-batch (list (request compiled 4))))
    (check-equal? (length result) 1)
    (check-equal? (generation-result-status (car result)) 'found)
    (check-not-false (member (generation-result-text (car result)) '(" a" " b"))))

  (test-case "fixed cohort preserves ordering, seed isolation, and physical width"
    (set-box! decode-widths '())
    (define compiled (compile-spec model* (choice (lit " a") (lit " b"))))
    (define seeds '(11 12 13 14 15 16))
    (define results
      (generate-batch (map (lambda (seed) (request compiled seed)) seeds)))
    (check-equal? (length results) (length seeds))
    (check-true (andmap (lambda (result)
                          (eq? 'found (generation-result-status result)))
                        results))
    (check-true (andmap (lambda (width) (= width 4)) (unbox decode-widths)))
    ;; One real request still executes in the same width-four profile.
    (set-box! decode-widths '())
    (define alone (car (generate-batch (list (request compiled 11)))))
    (check-true (andmap (lambda (width) (= width 4)) (unbox decode-widths)))
    (check-equal? (generation-result-token-ids alone)
                  (generation-result-token-ids (car results))))

  (test-case "first CARS attempt starts from prefetched prompt without reset"
    (define restores (box 0))
    (define first-provider
      (make-fake-cohort-provider
       #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 2
       #:start-lane (lambda (_prompt) (box 0))
       #:logits/lane (lambda (_session)
                       (vector->logits-view (vector 3.0 2.0 1.0 0.0)))
       #:commit-lane! (lambda (_session _id) (void))
       #:on-restore (lambda (lanes)
                      (set-box! restores (+ (unbox restores) (length lanes))))))
    (define first-model (make-backend tokenizer* first-provider void))
    (define compiled (compile-spec first-model (choice (lit " a") (lit " b"))))
    (define result (car (generate-batch (list (request compiled 9)))))
    (check-equal? (generation-result-status result) 'found)
    (check-equal? (unbox restores) 0)
    (backend-close! first-model))

  (test-case "each request owns a fresh CARS trie"
    (define compiled (compile-spec model* (lit " b")))
    (define results
      (generate-batch (for/list ([i (in-range 5)]) (request compiled i))))
    (check-equal? (length results) 5)
    (check-true
     (andmap (lambda (result)
               (positive? (generation-result-trie-nodes result)))
             results)))

  (test-case "rule-bearing compiled specs remain hard-only until calibration is attached"
    (define opens (box 0))
    (define guarded-provider
      (make-fake-cohort-provider
       #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 2
       #:start-lane (lambda (_prompt) (set-box! opens (add1 (unbox opens))) (box 0))
       #:logits/lane (lambda (_session)
                       (vector->logits-view (vector 3.0 2.0 1.0 0.0)))
       #:commit-lane! (lambda (_session _id) (void))))
    (define guarded-model (make-backend tokenizer* guarded-provider void))
    (define compiled
      (compile-spec guarded-model
                    (with-rules (text 1)
                                (rule-set "plain@1"
                                          (positive "has-a" (lit " a"))))))
    (define result (car (generate-batch (list (request compiled 1)))))
    (check-equal? (generation-result-status result) 'found)
    (check-false (generation-result-posterior result))
    (check-false (generation-result-terminal-mass result))
    (check-false (generation-result-calibration-fingerprint result))
    (check-true (positive? (unbox opens)))
    (check-exn #rx"keyword"
               (lambda ()
                 (generation-request compiled "" #:max-attempts 1 #:weak-model 'removed)))
    (backend-close! guarded-model))

  (test-case "backend failure returns aligned errors and closes a poisoned cohort"
    (define closes (box '()))
    (define failing-provider
      (make-provider
       #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 2
       #:open-cohort (lambda (_prompts) 'cohort)
       #:restore-lanes! (lambda (_cohort _lanes) (void))
       #:sample-factors (lambda (_cohort _entries) (error 'decode "injected"))
       #:decode! (lambda (_cohort _tokens) (void))
       #:close-cohort!
       (lambda (_cohort poisoned?)
         (set-box! closes (cons poisoned? (unbox closes))))))
    (define failing-model (make-backend tokenizer* failing-provider void))
    (define compiled (compile-spec failing-model (lit " a")))
    (define results
      (generate-batch (list (request compiled 1) (request compiled 2))))
    (check-equal? (map generation-result-status results)
                  '(backend-error backend-error))
    (check-equal? (unbox closes) '(#t))
    (backend-close! failing-model))

  (test-case "closed models fail before tokenizer or backend access"
    (define accesses (box 0))
    (define closed-tokenizer
      (make-tokenizer
       #:vocab-size 4
       #:fingerprint "closed-test-v1"
       #:token-ref (lambda (id) (set-box! accesses (add1 (unbox accesses)))
                     (vector-ref pieces id))
       #:tokenize (lambda (_text) (set-box! accesses (add1 (unbox accesses))) '())
       #:detokenize (lambda (_ids) (set-box! accesses (add1 (unbox accesses))) "")))
    (define closed-model (make-backend closed-tokenizer provider* void))
    (define compiled (compile-spec closed-model (text 1)))
    (backend-close! closed-model)
    (define before (unbox accesses))
    (check-exn #rx"model is closed" (lambda () (compile-spec closed-model (text 1))))
    (check-exn #rx"model is closed" (lambda () (observe-token-ids compiled '())))
    (check-exn #rx"model is closed"
               (lambda () (generate-batch (list (request compiled 1)))))
    (check-equal? (unbox accesses) before))

  (test-case "non-regex specs do not enumerate tokenizer vocabulary"
    (define piece-reads (box 0))
    (define lazy-tokenizer
      (make-tokenizer
       #:vocab-size 4 #:fingerprint "test-vocab"
       #:token-ref (lambda (id)
                     (set-box! piece-reads (add1 (unbox piece-reads)))
                     (vector-ref pieces id))
       #:tokenize (lambda (source) (if (string=? source " a") '(0) '()))
       #:detokenize (lambda (_ids) "")))
    (define lazy-model (make-backend lazy-tokenizer provider* void))
    (compile-spec lazy-model (text 2))
    (compile-spec lazy-model (choice (lit " a")))
    (check-equal? (unbox piece-reads) 0)
    (compile-spec lazy-model (ere "a*"))
    (check-equal? (unbox piece-reads) 4)
    (backend-close! lazy-model))

  (test-case "request context overflow fails before cohort open"
    (define opens (box 0))
    (define limited-provider
      (make-provider
       #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 2 #:context-limit 1
       #:open-cohort (lambda (_prompts) (set-box! opens (add1 (unbox opens))) 'c)
       #:restore-lanes! void #:sample-factors void #:decode! void
       #:close-cohort! void))
    (define limited-model (make-backend tokenizer* limited-provider void))
    (define compiled (compile-spec limited-model (text 2)))
    (check-exn #rx"exceeds the per-lane context"
               (lambda ()
                 (generate-batch (list (request compiled 1 #:max-tokens 2)))))
    (check-equal? (unbox opens) 0)
    (backend-close! limited-model))

  (test-case "cohort open failure returns aligned backend errors"
    (define closes (box 0))
    (define open-failing-provider
      (make-provider
       #:vocab-size 4 #:eog-token-ids '(3) #:cohort-width 2
       #:open-cohort (lambda (_prompts) (error 'open "injected"))
       #:restore-lanes! void #:sample-factors void #:decode! void
       #:close-cohort! (lambda (_cohort _poisoned?)
                         (set-box! closes (add1 (unbox closes))))))
    (define open-failing-model (make-backend tokenizer* open-failing-provider void))
    (define compiled (compile-spec open-failing-model (lit " a")))
    (define results
      (generate-batch (list (request compiled 1) (request compiled 2))))
    (check-equal? (map generation-result-status results)
                  '(backend-error backend-error))
    (check-equal? (unbox closes) 0)
    (backend-close! open-failing-model)))
