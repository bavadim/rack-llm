#lang racket/base

(require rackunit
         "../../main.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt")

(define pieces (vector " a" " b" " x" "<eog>"))
(define tokenizer*
  (tokenizer
   #:vocab-size 4
   #:token-ref (lambda (id) (vector-ref pieces id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define id (for/first ([piece (in-vector pieces)] [i (in-naturals)]
                                   #:when (string=? piece source)) i))
            (if id (list id) (error 'tokenize "unknown text ~s" source))]))
   #:detokenize (lambda (ids) (apply string-append (map (lambda (id) (vector-ref pieces id)) ids)))))
(define provider*
  (provider
   #:vocab-size 4 #:eog-token-ids '(3)
   #:start-session (lambda (_prompt) 'session)
   #:next-logits/session (lambda (_session) (vector->logits-view (vector 3.0 2.0 1.0 0.0)))
   #:commit-token! (lambda (_session _id) (void))
   #:end-session! (lambda (_session) (void))))
(define model* (model tokenizer* provider* (hash) void))

(module+ test
  (test-case "shape fingerprint ignores patterns but distinguishes program structure"
    (define left (compile-spec model* (control (text 1) (prefer (lit " a")))))
    (define right (compile-spec model* (control (text 1) (prefer (lit " b")))))
    (define other (compile-spec model* (control (text 2) (prefer (lit " a")))))
    (check-equal? (weak-observation-schema-fingerprint (observe left " a"))
                  (weak-observation-schema-fingerprint (observe right " b")))
    (check-not-equal? (weak-observation-schema-fingerprint (observe left " a"))
                      (weak-observation-schema-fingerprint (observe other " a")))
    (for-each compiled-spec-close! (list left right other)))

  (test-case "observe-many reuses the compiled vocabulary"
    (define refs (box 0))
    (define counted-tokenizer
      (tokenizer
       #:vocab-size 4
       #:token-ref (lambda (id)
                     (set-box! refs (add1 (unbox refs)))
                     (vector-ref pieces id))
       #:tokenize (lambda (source) (tokenize tokenizer* source))
       #:detokenize (lambda (ids) (detokenize tokenizer* ids))))
    (define counted-model (model counted-tokenizer provider* (hash) void))
    (define compiled
      (compile-spec counted-model (control (text 1) (prefer (lit " a")))))
    (define after-compile (unbox refs))
    (check-equal? (length (observe-many compiled '(" a" " b" " a" " b"))) 4)
    (check-equal? (unbox refs) after-compile)
    (compiled-spec-close! compiled)
    (model-close! counted-model))

  (test-case "hard CARS returns only the finite hard language"
    (define compiled (compile-spec model* (choice (list (lit " a") (lit " b")))))
    (define result
      (generate compiled ""
                #:sampler (cars-sampler #:max-attempts 20)
                #:temperature 1.0 #:max-tokens 1 #:seed 4))
    (check-equal? (generation-result-status result) 'found)
    (check-not-false (member (generation-result-text result) '(" a" " b")))
    (check-equal? (generation-result-distribution-guarantee result) 'exact-hard)
    (compiled-spec-close! compiled))

  (test-case "scoped literal ban removes an otherwise likely token"
    (define compiled (compile-spec model* (control (text 1) (ban (lit " a")))))
    (define result
      (generate compiled ""
                #:sampler (cars-sampler #:max-attempts 20)
                #:temperature 1.0 #:max-tokens 1 #:seed 2))
    (check-equal? (generation-result-status result) 'found)
    (check-not-equal? (generation-result-text result) " a")
    (compiled-spec-close! compiled))

  (test-case "end-anchored ban is enforced by CARS"
    (define compiled (compile-spec model* (control (text 1) (ban (ere " a$")))))
    (define results
      (for/list ([seed (in-range 20)])
        (generate compiled "" #:sampler (cars-sampler #:max-attempts 20)
                  #:temperature 1.0 #:max-tokens 1 #:seed seed)))
    (check-false (ormap (lambda (result) (string=? (generation-result-text result) " a"))
                        results))
    (compiled-spec-close! compiled))

  (test-case "observe uses original result token ids and stable schema"
    (define spec
      (control (text 1)
               (prefer (lit " a"))
               (avoid (ere "x$"))))
    (define compiled (compile-spec model* spec))
    (define result
      (generate compiled "" #:sampler (cars-sampler #:max-attempts 10)
                #:temperature 1.0 #:max-tokens 1 #:seed 8))
    (check-false (generation-result-weak result))
    (check-equal? (generation-metrics-weak-evaluations
                   (generation-result-metrics result)) 0)
    (define observation (observe compiled result))
    (check-equal? (vector-length (weak-observation-labels observation)) 2)
    (check-equal? (vector->list (weak-observation-rule-paths observation))
                  '("root/control/rule[0]" "root/control/rule[1]"))
    (compiled-spec-close! compiled)))
