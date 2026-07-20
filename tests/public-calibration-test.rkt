#lang racket/base

(require json
         racket/file
         rackunit
         "../main.rkt")

(define rules
  (rule-set
   "public/calibration@1"
   (positive "positive-a" (lit "PA"))
   (positive "positive-b" (lit "PB"))
   (negative "negative-a" (lit "NA"))
   (negative "negative-b" (lit "NB"))))

(define calibration-strings
  (append
   (for/list ([i (in-range 300)])
     (string-append "PA PB" (if (zero? (modulo i 17)) " NA" "")))
   (for/list ([i (in-range 300)])
     (string-append "NA NB" (if (zero? (modulo i 19)) " PA" "")))
   (for/list ([i (in-range 80)])
     (if (even? i) "PA NB" "PB NA"))))

(define (observation-from-saved payload labels)
  (datum->observation
   (hash 'format "rack-llm-observation"
         'version 1
         'schema (hash-ref payload 'schema)
         'labels labels)))

(module+ test
  (test-case "public calibration is model-free and serializable"
    (define fitted (fit-calibration rules calibration-strings #:seed 41))
    (define path (make-temporary-file "rack-llm-public-calibration-~a.json"))
    (dynamic-wind
      void
      (lambda ()
        (save-calibration fitted path)
        (define payload (call-with-input-file path read-json))
        (define positive (observation-from-saved payload '(1 1 0 0)))
        (define negative (observation-from-saved payload '(0 0 -1 -1)))
        (check-true (> (calibration-posterior fitted positive) 0.8))
        (check-true (< (calibration-posterior fitted negative) 0.2))
        (define loaded (load-calibration path))
        (check-equal? (calibration-fingerprint loaded)
                      (calibration-fingerprint fitted))
        (check-= (calibration-posterior loaded positive)
                 (calibration-posterior fitted positive)
                 1e-12))
      (lambda ()
        (when (file-exists? path) (delete-file path))))))
