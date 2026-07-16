#lang racket/base

(require racket/list
         rackunit
         "../../main.rkt"
         "../../private/guidance.rkt"
         "../../private/logits.rkt"
         "../../private/model.rkt"
         "../../private/weak.rkt")

(define vocab (vector " a" " b" " c" " d" "<eog>"))
(define tok
  (tokenizer
   #:vocab-size 5
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define found
              (for/first ([piece (in-vector vocab)] [id (in-naturals)]
                          #:when (string=? piece source)) id))
            (if found (list found) (error 'tokenize "unexpected text ~s" source))]))
   #:detokenize (lambda (ids) (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))

(define starts (box 0))
(define ends (box 0))
(define probabilities '(0.4 0.3 0.15 0.05 0.1))
(define provider*
  (provider
   #:vocab-size 5
   #:eog-token-ids '(4)
   #:start-session (lambda (_prompt) (set-box! starts (add1 (unbox starts))) 'session)
   #:next-logits/session
   (lambda (_session) (vector->logits-view (list->vector (map log probabilities))))
   #:commit-token! (lambda (_session _id) (void))
   #:end-session! (lambda (_session) (set-box! ends (add1 (unbox ends))))))
(define model* (model tok provider* (hash 'name 'tiny-pwsg) void))

(define spec
  (control
   (choice (map lit '(" a" " b" " c" " d")))
   (prefer (lit " a"))
   (prefer (lit " b"))
   (avoid (lit " c"))
   (avoid (lit " d"))))

(define compiled (compile-spec model* spec))

(define calibration
  (append
   (make-list 470 (observe compiled " a"))
   (make-list 450 (observe compiled " b"))
   (make-list 390 (observe compiled " c"))
   (make-list 380 (observe compiled " d"))))

(module+ test
  (test-case "prefix-overlapping sequence samples the hard language exactly"
    (define prefix
      (compile-spec
       model*
       (seq (list (choice (list (lit " a")
                                (seq (list (lit " a") (lit " b")))))
                  (lit " c")))))
    (define generator
      (make-generator prefix ""
                      #:sampler (cars-sampler #:max-attempts 100)
                      #:temperature 1.0 #:max-tokens 4 #:seed 101))
    (define results (generator-sample-n! generator 4000))
    (define outcomes '(" a c" " a b c"))
    (define raw (vector (* 0.4 0.15) (* 0.4 0.3 0.15)))
    (define z (for/sum ([x (in-vector raw)]) x))
    (define tv
      (* 0.5
         (for/sum ([text (in-list outcomes)] [weight (in-vector raw)])
           (abs (- (/ (count (lambda (result)
                              (string=? text (generation-result-text result)))
                            results)
                      (length results))
                   (/ weight z))))))
    (check-true (< tv 0.035)
                (format "tv=~a counts=~a"
                        tv
                        (map (lambda (text)
                               (count (lambda (result)
                                        (string=? text (generation-result-text result)))
                                      results))
                             outcomes)))
    (generator-close! generator)
    (compiled-spec-close! prefix))

  (test-case "ambiguous repeat derivations do not multiply terminal mass"
    (define ambiguous
      (compile-spec
       model*
       (repeat 1 2
               (choice (list (lit " a")
                             (seq (list (lit " a") (lit " a"))))))))
    (define generator
      (make-generator ambiguous ""
                      #:sampler (cars-sampler #:max-attempts 100)
                      #:temperature 1.0 #:max-tokens 5 #:seed 203))
    (define results (generator-sample-n! generator 5000))
    (define outcomes
      (for/list ([n (in-range 1 5)])
        (apply string-append (make-list n " a"))))
    (define raw (for/vector ([n (in-range 1 5)]) (expt 0.4 n)))
    (define z (for/sum ([x (in-vector raw)]) x))
    (define tv
      (* 0.5
         (for/sum ([text (in-list outcomes)] [weight (in-vector raw)])
           (abs (- (/ (count (lambda (result)
                              (string=? text (generation-result-text result)))
                            results)
                      (length results))
                   (/ weight z))))))
    (check-true (< tv 0.035)
                (format "tv=~a counts=~a"
                        tv
                        (map (lambda (text)
                               (count (lambda (result)
                                        (string=? text (generation-result-text result)))
                                      results))
                             outcomes)))
    (generator-close! generator)
    (compiled-spec-close! ambiguous))

  (test-case "multi-token shared prefixes stay exact with a frozen reused trie"
    (define multi
      (compile-spec
       model*
       (choice (list (seq (list (lit " a") (lit " b")))
                     (seq (list (lit " a") (lit " c")))
                     (lit " d")))))
    (define generator
      (make-generator multi ""
                      #:sampler (cars-sampler #:max-attempts 100 #:max-trie-nodes 2)
                      #:temperature 1.0 #:max-tokens 3 #:seed 29))
    (define results
      (append (generator-sample-n! generator 2000)
              (generator-sample-n! generator 2000)))
    (define outcomes '(" a b" " a c" " d"))
    (define raw #(0.12 0.06 0.05))
    (define z (for/sum ([x (in-vector raw)]) x))
    (define tv
      (* 0.5
         (for/sum ([text (in-list outcomes)] [weight (in-vector raw)])
           (abs (- (/ (count (lambda (result)
                              (string=? text (generation-result-text result)))
                            results)
                      (length results))
                   (/ weight z))))))
    (check-true (< tv 0.035))
    (check-true (generation-metrics-trie-frozen?
                 (generation-result-metrics (last results))))
    (generator-close! generator)
    (compiled-spec-close! multi))

  (test-case "PWSG CARS samples Q times posterior and reuses its fractional trie"
    (set-box! starts 0)
    (set-box! ends 0)
    (define weak-model (fit-weak-model calibration))
    (define qs
      (for/vector ([source (in-list '(" a" " b" " c" " d"))])
        (weak-posterior weak-model (observe compiled source))))
    (define raw
      (for/vector ([base (in-list (take probabilities 4))] [q (in-vector qs)]) (* base q)))
    (define z (for/sum ([x (in-vector raw)]) x))
    (define expected (for/vector ([x (in-vector raw)]) (/ x z)))
    (define generator
      (make-generator compiled ""
                      #:sampler (cars-sampler #:max-attempts 100 #:weak-model weak-model)
                      #:temperature 1.0 #:max-tokens 1 #:seed 17))
    (define results (generator-sample-n! generator 5000))
    (check-true (andmap (lambda (result) (eq? (generation-result-status result) 'found)) results))
    (for ([id (in-range 4)])
      (define observed
        (/ (count (lambda (result) (equal? (generation-result-token-ids result) (list id))) results)
           (length results)))
      (check-= observed (vector-ref expected id) 0.035))
    (define last-metrics (generation-result-metrics (last results)))
    (check-true (> (generation-metrics-trie-nodes last-metrics) 1))
    (check-true (> (generation-metrics-weak-cache-hits last-metrics) 0))
    (check-equal? (unbox starts) (unbox ends))
    (generator-close! generator)

    (define ordered (sort (vector->list qs) <))
    (define threshold (/ (+ (list-ref ordered 1) (list-ref ordered 2)) 2.0))
    (define threshold-raw
      (for/vector ([base (in-list (take probabilities 4))] [q (in-vector qs)])
        (if (>= q threshold) (* base q) 0.0)))
    (define threshold-z (for/sum ([x (in-vector threshold-raw)]) x))
    (define threshold-generator
      (make-generator compiled ""
                      #:sampler (cars-sampler #:max-attempts 100 #:weak-model weak-model
                                               #:min-posterior threshold)
                      #:temperature 1.0 #:max-tokens 1 #:seed 71))
    (define threshold-results (generator-sample-n! threshold-generator 2500))
    (define tv
      (* 0.5
         (for/sum ([id (in-range 4)] [weight (in-vector threshold-raw)])
           (abs (- (/ (count (lambda (result)
                              (equal? (generation-result-token-ids result) (list id)))
                            threshold-results)
                      (length threshold-results))
                   (/ weight threshold-z))))))
    (check-true (< tv 0.035))
    (generator-close! threshold-generator))

  (test-case "terminal cache survives CarsNode envelope mutation"
    (define one-path-provider
      (provider
       #:vocab-size 5
       #:eog-token-ids '(4)
       #:start-session (lambda (_prompt) 'one-path-session)
       #:next-logits/session
       (lambda (_session)
         (vector->logits-view (vector 0.0 -inf.0 -inf.0 -inf.0 0.0)))
       #:commit-token! (lambda (_session _id) (void))
       #:end-session! (lambda (_session) (void))))
    (define one-path-model (model tok one-path-provider (hash 'name 'one-path) void))
    (define one-path-compiled (compile-spec one-path-model spec))
    (define weak-model (fit-weak-model calibration))
    (define generator
      (make-generator one-path-compiled ""
                      #:sampler (cars-sampler #:max-attempts 10
                                               #:weak-model weak-model)
                      #:temperature 1.0 #:max-tokens 1 #:seed 1))
    (dynamic-wind
      void
      (lambda ()
        (define first (generator-sample! generator))
        (define second (generator-sample! generator))
        (check-equal? (generation-result-status first) 'found)
        (check-equal? (generation-result-status second) 'found)
        (check-equal? (generation-result-token-ids first) '(0))
        (check-equal? (generation-result-token-ids second) '(0))
        (define first-metrics (generation-result-metrics first))
        (define second-metrics (generation-result-metrics second))
        (check-equal? (generation-metrics-weak-evaluations first-metrics) 1)
        (check-equal? (generation-metrics-attempts second-metrics) 1)
        (check-equal? (generation-metrics-weak-evaluations second-metrics) 0)
        (check-equal? (generation-metrics-weak-cache-hits second-metrics) 1)
        (check-eq?
         (weak-result-observation (generation-result-weak first))
         (weak-result-observation (generation-result-weak second))))
      (lambda ()
        (generator-close! generator)
        (compiled-spec-close! one-path-compiled)
        (model-close! one-path-model))))

  (test-case "schema mismatch and unsupported PWSG spec fail before sessions"
    (define weak-model (fit-weak-model calibration))
    (define before (unbox starts))
    (check-exn #rx"unsupported PWSG program"
               (lambda ()
                 (define bad
                   (compile-spec
                    model*
                    (control
                     (rx " a")
                     (prefer (lit " a"))
                     (prefer (lit " b"))
                     (avoid (lit " c"))
                     (avoid (lit " d")))))
                 (dynamic-wind void
                               (lambda ()
                                 (make-generator bad ""
                                                 #:sampler (cars-sampler #:max-attempts 2
                                                                        #:weak-model weak-model)))
                               (lambda () (compiled-spec-close! bad)))))
    (check-exn #rx"incompatible weak model"
               (lambda ()
                 (define bad (compile-spec model* (control (text 1) (prefer (lit " a")))))
                 (dynamic-wind void
                               (lambda ()
                                 (make-generator bad ""
                                                 #:sampler (cars-sampler #:max-attempts 2
                                                                        #:weak-model weak-model)))
                               (lambda () (compiled-spec-close! bad)))))
    (check-equal? (unbox starts) before))

  (test-case "attempt exhaustion returns no approximate fallback"
    (define empty (compile-spec model* (choice '())))
    (define result
      (generate empty "" #:sampler (cars-sampler #:max-attempts 1)
                #:temperature 1.0 #:max-tokens 1 #:seed 3))
    (compiled-spec-close! empty)
    (check-not-false (member (generation-result-status result)
                             '(not-found-attempt-budget not-found-support)))
    (check-false (generation-result-hard-ok? result))))
