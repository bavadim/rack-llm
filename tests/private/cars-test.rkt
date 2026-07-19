#lang racket/base

(require racket/list
         rackunit
         "../../main.rkt"
         "../../backend.rkt"
         "../support/logits.rkt"
         "../../private/cars.rkt"
         "../../private/domain.rkt"
         "../support/fake-cohort.rkt")

(define vocab (vector " a" " b" " c" " d" "<eog>"))
(define tok
  (make-tokenizer
   #:vocab-size 5
   #:fingerprint "cars-test-v1"
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize
   (lambda (source)
     (cond [(string=? source "") '()]
           [else
            (define found
              (for/first ([piece (in-vector vocab)] [id (in-naturals)]
                          #:when (string=? piece source)) id))
            (if found (list found) (error 'tokenize "unexpected text ~s" source))]))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))

(define probabilities '(0.4 0.3 0.15 0.05 0.1))
(define provider*
  (make-fake-cohort-provider
   #:vocab-size 5 #:eog-token-ids '(4) #:cohort-width 8
   #:start-lane (lambda (_prompt) (box '()))
   #:logits/lane
   (lambda (_session)
     (vector->logits-view (list->vector (map log probabilities))))
   #:commit-lane! (lambda (session id) (set-box! session (cons id (unbox session))))))
(define model* (make-backend tok provider* void))

(define (requests compiled count #:attempts [attempts 100] #:max-tokens [max-tokens 4])
  (for/list ([seed (in-range count)])
    (generation-request
     compiled "" #:max-attempts attempts
     #:temperature 1.0 #:max-tokens max-tokens #:seed seed)))

(module+ test
  (test-case "cached CARS mass matches full finite-tree recomputation"
    (define trie (make-cars-trie))
    (define root (cars-trie-root trie))
    (define a (cars-node-child! trie root 0 0.2))
    (define b (cars-node-child! trie root 1 0.3))
    (define c (cars-node-child! trie root 2 0.5))
    (cars-commit! (list (make-cars-domain-update root (domain-only '(0 1 2)) 1.0))
                  a 0.4)
    (check-= (cars-node-mass root) (- 1.0 (* 0.2 0.6)) 1e-12)
    (cars-commit! '() b 0.25)
    (check-= (cars-node-mass root)
             (- 1.0 (* 0.2 0.6) (* 0.3 0.75)) 1e-12)
    (define nested (cars-node-child! trie c 3 0.6))
    (cars-commit! (list (make-cars-domain-update c (domain-only '(3)) 0.6))
                  nested 0.5)
    (define c-mass (- 0.6 (* 0.6 0.5)))
    (check-= (cars-node-mass c) c-mass 1e-12)
    (check-= (cars-node-mass root)
             (- 1.0 (* 0.2 0.6) (* 0.3 0.75) (* 0.5 (- 1.0 c-mass)))
             1e-12))

  (test-case "CARS matches a finite conditional distribution"
    (define compiled
      (compile-spec
       model*
       (seq (choice (lit " a") (seq (lit " a") (lit " b"))) (lit " c"))))
    (define results (generate-batch (requests compiled 4000)))
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
    (check-true (< tv 0.04) (format "tv=~a" tv))
    (check-true (andmap (lambda (result) (eq? (generation-result-status result) 'found)) results)))

  (test-case "prefix logits are consumed after every fixed-width decode"
    (define prefix-provider
      (make-fake-cohort-provider
       #:vocab-size 5 #:eog-token-ids '(4) #:cohort-width 4
       #:start-lane (lambda (_prompt) (box 0))
       #:logits/lane
       (lambda (session)
         (vector->logits-view
          (if (zero? (unbox session))
              (vector 6.0 1.0 -2.0 -2.0 -4.0)
              (vector -3.0 6.0 2.0 -2.0 0.0))))
       #:commit-lane! (lambda (session _id) (set-box! session (add1 (unbox session))))))
    (define prefix-model (make-backend tok prefix-provider void))
    (define compiled (compile-spec prefix-model (seq (lit " a") (lit " b"))))
    (define results (generate-batch (requests compiled 40 #:max-tokens 2)))
    (check-true (andmap (lambda (r) (string=? (generation-result-text r) " a b"))
                        results))
    (backend-close! prefix-model))

  (test-case "affine posterior mass preserves the exact finite target distribution"
    (define compiled
      (compile-spec
       model*
       (with-rules
        (apply choice (map lit '(" a" " b" " c" " d")))
        (rule-set "finite-policy@1"
                  (positive "a" (lit " a")) (positive "b" (lit " b"))
                  (negative "c" (lit " c")) (negative "d" (lit " d"))))))
    (define calibration
      (append (make-list 100 (observe-token-ids compiled '(0)))
              (make-list 90 (observe-token-ids compiled '(1)))
              (make-list 40 (observe-token-ids compiled '(2)))
              (make-list 30 (observe-token-ids compiled '(3)))))
    (define fitted (fit-calibration calibration #:seed 7))
    (define good 0.8)
    (define bad 0.2)
    (define guided (attach-calibration compiled fitted #:good good #:bad bad))
    (define texts '(" a" " b" " c" " d"))
    (define posterior-by-text
      (for/hash ([text (in-list texts)])
        (values text (calibration-posterior fitted (observe compiled text)))))
    (define rs
      (for/list ([seed (in-range 5000)])
        (generation-request
         guided "" #:max-attempts 100
         #:temperature 1.0 #:max-tokens 1 #:seed (+ 1000003 (* 7919 seed)))))
    (define results (generate-batch rs))
    (define raw
      (for/list ([text (in-list texts)] [q (in-list (take probabilities 4))])
        (define p (hash-ref posterior-by-text text))
        (* q (/ (+ (* good p) (* bad (- 1.0 p))) (max good bad)))))
    (define z (apply + raw))
    (define tv
      (* 0.5
         (for/sum ([text (in-list texts)] [weight (in-list raw)])
           (abs (- (/ (count (lambda (result)
                              (string=? text (generation-result-text result)))
                            results)
                      (length results))
                   (/ weight z))))))
    (check-true (< tv 0.04) (format "guided tv=~a" tv))
    (for ([result (in-list results)])
      (define p (hash-ref posterior-by-text (generation-result-text result)))
      (check-= (generation-result-posterior result) p 1e-12)
      (check-= (generation-result-terminal-mass result)
               (/ (+ (* good p) (* bad (- 1.0 p))) (max good bad)) 1e-12)
      (check-equal? (generation-result-calibration-fingerprint result)
                    (calibration-fingerprint fitted)))
    (define default-result
      (car (generate-batch
            (list (generation-request (attach-calibration compiled fitted) ""
                                      #:max-attempts 100 #:temperature 1.0
                                      #:max-tokens 1 #:seed 7000)))))
    (check-= (generation-result-terminal-mass default-result)
             (generation-result-posterior default-result) 1e-12)
    ;; Parameters may vary across tasks, but logical rule identity and order may not.
    (define parameterized
      (compile-spec
       model*
       (with-rules
        (seq (lit " a") (lit " b"))
        (rule-set "finite-policy@1"
                  (positive "a" (lit " b")) (positive "b" (lit " a"))
                  (negative "c" (lit " d")) (negative "d" (lit " c"))))))
    (define guided-parameterized (attach-calibration parameterized fitted))
    (define stopped
      (car (generate-batch
            (list (generation-request guided-parameterized "" #:max-attempts 10
                                      #:max-model-draws 1 #:temperature 1.0
                                      #:max-tokens 2 #:seed 71)))))
    (check-equal? (generation-result-status stopped) 'not-found-model-draw-budget)
    (check-equal? (generation-result-calibration-fingerprint stopped)
                  (calibration-fingerprint fitted))
    (define reordered
      (compile-spec
       model*
       (with-rules
        (text 1)
        (rule-set "finite-policy@1"
                  (positive "b" (lit " b")) (positive "a" (lit " a"))
                  (negative "c" (lit " c")) (negative "d" (lit " d"))))))
    (check-exn #rx"schema does not match"
               (lambda () (attach-calibration reordered fitted)))
    (for ([weights (in-list '((0 0) (-1 1) (1 -1) (+inf.0 1) (+nan.0 1)))])
      (check-exn exn:fail?
                 (lambda ()
                   (attach-calibration compiled fitted
                                       #:good (car weights) #:bad (cadr weights))))))

  (test-case "model draw budget stops inside an attempt"
    (define compiled
      (compile-spec model* (seq (lit " a") (lit " b"))))
    (define result
      (car (generate-batch
            (list (generation-request
                          compiled "" #:max-attempts 100 #:max-model-draws 1
                          #:temperature 1.0 #:max-tokens 2 #:seed 9)))))
    (check-equal? (generation-result-status result) 'not-found-model-draw-budget)
    (check-true (<= (generation-result-model-draws result) 1)))

  (test-case "empty hard support has no approximate fallback"
    (define compiled (compile-spec model* (ere " a a")))
    (define result
      (car (generate-batch
            (list (generation-request
                          compiled "" #:max-attempts 1
                          #:temperature 1.0 #:max-tokens 1 #:seed 3)))))
    (check-not-false
     (member (generation-result-status result)
             '(not-found-attempt-budget not-found-support)))
    (check-not-equal? (generation-result-status result) 'found)))
