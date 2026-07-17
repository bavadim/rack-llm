#lang racket/base
(require json rackunit racket/file "../../private/weak.rkt")
(define signs '(1 1 -1 -1))
(define (observation fires)
  (list->vector (map (lambda (fire? sign) (if fire? sign 0)) fires signs)))
(define (synthetic count seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (parameterize ([current-pseudo-random-generator rng])
    (for/list ([_ (in-range count)])
      (define good? (< (random) 0.55))
      (define ps (if good? '(0.85 0.72 0.18 0.25) '(0.20 0.28 0.82 0.70)))
      (observation (map (lambda (p) (< (random) p)) ps)))))
(module+ test
  (test-case "signed EM recovers oriented reliabilities"
    (define model (fit-weak-model (synthetic 4000 91)))
    (check-true (> (weak-posterior model (observation '(#t #t #f #f))) 0.8))
    (check-true (< (weak-posterior model (observation '(#f #f #t #t))) 0.2))
    (check-equal? (hash-ref (weak-model-diagnostics model) 'active-rules) 4))
  (test-case "diagnostics are JSON serializable"
    (define out (open-output-string))
    (write-json (weak-model-diagnostics (fit-weak-model (synthetic 500 811))) out)
    (check-true (positive? (string-length (get-output-string out)))))
  (test-case "invalid, duplicate and mismatched columns fail"
    (check-exn #rx"invalid weak label" (lambda () (fit-weak-model (list #(1 0 2)))))
    (check-exn #rx"incompatible" (lambda () (fit-weak-model (list #(1 0 -1) #(1 0)))))
    (check-exn #rx"duplicate rule columns"
               (lambda () (fit-weak-model
                           (for/list ([i (in-range 20)])
                             (if (even? i) #(1 1 -1 -1) #(0 0 0 0)))))))
  (test-case "arity is checked while scoring"
    (define model (fit-weak-model (synthetic 500 12)))
    (check-exn #rx"width" (lambda () (weak-posterior model #(1 0 -1)))))
  (test-case "JSON round-trip preserves posterior and fingerprint"
    (define model (fit-weak-model (synthetic 2000 19)))
    (define path (make-temporary-file "rack-llm-weak-~a.json"))
    (dynamic-wind void
      (lambda ()
        (save-weak-model model path)
        (define loaded (load-weak-model path))
        (check-equal? (weak-model-fingerprint loaded) (weak-model-fingerprint model))
        (check-= (weak-posterior loaded #(1 0 0 0))
                 (weak-posterior model #(1 0 0 0)) 1e-12))
      (lambda () (when (file-exists? path) (delete-file path)))))
  (test-case "old artifacts fail closed"
    (define path (make-temporary-file "rack-llm-weak-old-~a.json"))
    (dynamic-wind void
      (lambda ()
        (call-with-output-file path #:exists 'truncate
          (lambda (out) (write-json (hash 'format "rack-llm-weak-model" 'version 5) out)))
        (check-exn #rx"unsupported" (lambda () (load-weak-model path))))
      (lambda () (when (file-exists? path) (delete-file path))))))
