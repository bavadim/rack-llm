#lang racket/base

(require racket/runtime-path
         rackunit
         "../main.rkt")

(define-runtime-path core-module "../main.rkt")
(define-runtime-path llama-module "../model-llama-cpp.rkt")
(define (exported-value module-path name)
  (with-handlers ([exn:fail? (lambda (_exn) 'missing)])
    (dynamic-require module-path name (lambda () 'missing))))

(module+ test
  (test-case "public API is the exact hard/PWSG surface"
    (for ([name (in-list
                 '(model-metadata model-close!
                   lit rx ere pure seq choice repeat bind text control prefer avoid ban
                   pwsg-compatible? observe fit-weak-model weak-posterior
                   save-weak-model load-weak-model cars-sampler make-generator
                   generator-sample! generator-sample-n! generator-close! generate
                   weak-observation-labels weak-model-fingerprint
                   generation-result-weak generation-result-observation
                   generation-result-distribution-guarantee
                   generation-metrics-hard-proposals generation-metrics-weak-rejections))])
      (check-not-equal? (exported-value core-module name) 'missing
                        (format "~a should be exported" name)))
    (for ([name (in-list '(score rank rank-rx weight ban-rx local-sampler
                           TextObserver guidance-score guidance-potential
                           program-score-ceiling))])
      (check-equal? (exported-value core-module name) 'missing
                    (format "~a should not be exported" name))))

  (test-case "ERE accepts only the documented portable grammar"
    (for ([pattern (in-list '("US[0-9]+" "(a|b){1,3}" "^a.*b$" "[^x]" "a\\+b"))])
      (check-not-exn (lambda () (ere pattern)) pattern))
    (for ([pattern (in-list '("(?i)a" "(?=a)b" "\\d+" "\\bword\\b" "(a)\\1" "a*?"))])
      (check-exn #rx"ere" (lambda () (ere pattern)) pattern))
    (check-not-exn (lambda () (rx "(?i)\\bword\\b"))))

  (test-case "new constructors enforce pattern and layout contracts"
    (check-exn #rx"lit or ere" (lambda () (prefer (rx "a"))))
    (check-true (pwsg-compatible? (control (text 8) (prefer (ere "a")))))
    (check-false (pwsg-compatible? (seq (list (text 8) (lit "suffix")))))
    (check-false (pwsg-compatible? (bind (lit "a") (lambda (_v) (lit "b"))))))

  (test-case "llama backend keeps one public constructor"
    (check-not-equal? (exported-value llama-module 'llama-cpp-model) 'missing)
    (check-equal? (exported-value llama-module 'make-llama-cpp-backend) 'missing)))
