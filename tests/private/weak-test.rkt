#lang racket/base
(require json rackunit racket/file "../../private/program.rkt" "../../private/weak.rkt")
(define signs '(1 1 -1 -1))
(define (schema-for id signs)
  (program-schema
   (compile-program
    (with-rules
     (text 32)
     (apply rule-set id
            (for/list ([sign (in-list signs)] [i (in-naturals)])
              ((if (= sign 1) positive negative) (format "r~a" i) (lit (format "v~a" i))))))
    (lambda (_) '()) #f)))
(define schema (schema-for "weak/synthetic@1" signs))
(define (label-vector fires)
  (list->vector (map (lambda (fire? sign) (if fire? sign 0)) fires signs)))
(define (synthetic count seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (parameterize ([current-pseudo-random-generator rng])
    (for/list ([_ (in-range count)])
      (define good? (< (random) 0.55))
      (define ps (if good? '(0.85 0.72 0.18 0.25) '(0.20 0.28 0.82 0.70)))
      (make-observation schema (label-vector (map (lambda (p) (< (random) p)) ps))))))
(module+ test
  (test-case "signed EM recovers oriented reliabilities"
    (define model (fit-calibration (synthetic 4000 91)))
    (check-true (> (calibration-posterior model
                                         (make-observation schema (label-vector '(#t #t #f #f)))) 0.8))
    (check-true (< (calibration-posterior model
                                         (make-observation schema (label-vector '(#f #f #t #t)))) 0.2))
    (check-equal? (hash-ref (calibration-diagnostics model) 'active-rules) 4))
  (test-case "diagnostics are JSON serializable"
    (define out (open-output-string))
    (write-json (calibration-diagnostics (fit-calibration (synthetic 500 811))) out)
    (check-true (positive? (string-length (get-output-string out)))))
  (test-case "fixed rules can calibrate directly from strings"
    (define rs
      (rule-set "weak/direct@1" (positive "p1" (lit "P1")) (positive "p2" (lit "P2"))
                (negative "n1" (lit "N1")) (negative "n2" (lit "N2"))))
    (define strings
      (for/list ([o (in-list (synthetic 1000 72))])
        (apply string-append
               (for/list ([label (in-vector (observation-labels o))]
                          [marker (in-list '("P1" "P2" "N1" "N2"))]
                          #:unless (zero? label)) marker))))
    (define model (fit-calibration rs strings #:seed 4))
    (check-equal? (rule-schema-id (calibration-schema model)) "weak/direct@1")
    (check-equal? (sort (hash-keys (hash-ref (calibration-diagnostics model) 'rule-weights)) symbol<?)
                  '(n1 n2 p1 p2)))
  (test-case "constant and exact duplicate columns are projected deterministically"
    (define extended (schema-for "weak/projection@1" '(1 1 -1 -1 1 -1)))
    (define rows
      (for/list ([o (in-list (synthetic 1000 44))])
        (define v (observation-labels o))
        (make-observation extended
                          (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2)
                                  (vector-ref v 3) (vector-ref v 0) 0))))
    (define diagnostics (calibration-diagnostics (fit-calibration rows)))
    (check-equal? (hash-ref diagnostics 'selected-source-slots) '(0 1 2 3))
    (check-equal? (hash-ref diagnostics 'constant-source-slots) '(5))
    (check-equal? (hash-ref diagnostics 'duplicate-source-slots)
                  (list (hash 'slot 4 'duplicate-of 0))))
  (test-case "invalid labels, mixed schemas and widths fail closed"
    (check-exn #rx"invalid weak label" (lambda () (make-observation schema #(1 0 2 0))))
    (check-exn #rx"contradicts declared rule polarity"
               (lambda () (make-observation schema #(-1 0 0 0))))
    (check-exn #rx"contradicts declared rule polarity"
               (lambda () (datum->observation
                           (hash 'format "rack-llm-observation" 'version 1
                                 'schema (rule-schema->datum schema)
                                 'labels '(1 0 1 0)))))
    (define other (schema-for "weak/other@1" signs))
    (check-exn #rx"different rule schemas"
               (lambda () (fit-calibration
                           (list (car (synthetic 10 1))
                                 (make-observation other #(1 0 -1 0))))))
    (define model (fit-calibration (synthetic 500 12)))
    (check-exn #rx"width" (lambda () (calibration-posterior/row model #(1 0 -1)))))
  (test-case "JSON round-trip preserves posterior and fingerprint"
    (define model (fit-calibration (synthetic 2000 19)))
    (define path (make-temporary-file "rack-llm-weak-~a.json"))
    (dynamic-wind void
      (lambda ()
        (save-calibration model path)
        (define loaded (load-calibration path))
        (check-equal? (calibration-fingerprint loaded) (calibration-fingerprint model))
        (define sample (make-observation schema #(1 0 0 0)))
        (check-= (calibration-posterior loaded sample)
                 (calibration-posterior model sample) 1e-12)
        (check-equal? (datum->observation (observation->datum sample)) sample))
      (lambda () (when (file-exists? path) (delete-file path)))))
  (test-case "old artifacts fail closed"
    (define path (make-temporary-file "rack-llm-weak-old-~a.json"))
    (dynamic-wind void
      (lambda ()
        (call-with-output-file path #:exists 'truncate
          (lambda (out) (write-json (hash 'format "rack-llm-weak-model" 'version 5) out)))
        (check-exn #rx"unsupported" (lambda () (load-calibration path))))
      (lambda () (when (file-exists? path) (delete-file path))))))
