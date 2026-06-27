#lang racket/base

(require rackunit
         rack-llm/resampling
         rack-llm/rules/threshold-acceptance)

(define cfg
  (resampling-config 5 10 60000 'return-fail))

(define resampling-tests
  (test-suite
   "rule-based resampling loop"

   (test-case "resampling returns first accepted candidate"
     (define result
       (resample-until-accepted cfg
                                (in-list '("bad-1" "bad-2" "good"))
                                accept-if-good))
     (check-equal? (resampling-result-status result) 'accepted)
     (check-equal? (resampling-result-selected result) "good")
     (check-equal? (resampling-result-selected-rank result) 3)
     (check-equal? (resampling-result-checked result) 3)
     (check-equal? (length (resampling-result-trace result)) 3))

   (test-case "resampling returns failed report when all candidates reject"
     (define result
       (resample-until-accepted (resampling-config 2 10 60000 'return-fail)
                                (in-list '("bad-1" "bad-2" "good"))
                                accept-if-good))
     (check-equal? (resampling-result-status result) 'failed)
     (check-false (resampling-result-selected result))
     (check-equal? (resampling-result-checked result) 2)
     (check-equal? (length (resampling-result-trace result)) 2))

   (test-case "resampling can return best rejected candidate by score"
     (define result
       (resample-until-accepted
        (resampling-config 3 10 60000 'return-best-by-score)
        (in-list '("score:0.1" "score:0.9" "score:0.2"))
        score-only))
     (check-equal? (resampling-result-status result) 'failed)
     (check-equal? (resampling-result-selected result) "score:0.9")
     (check-equal? (resampling-result-selected-rank result) 2))))

(define (accept-if-good candidate)
  (if (equal? candidate "good")
      (acceptance-decision #t #t 1.0 (hash 'ok 1.0) '())
      (acceptance-decision #f #t 0.0 (hash 'ok 0.0) (list "not good"))))

(define (score-only candidate)
  (define score
    (cond
      [(equal? candidate "score:0.9") 0.9]
      [(equal? candidate "score:0.2") 0.2]
      [else 0.1]))
  (acceptance-decision #f #t score (hash 'score score) (list "rejected")))

(module+ test
  (require rackunit/text-ui)
  (run-tests resampling-tests))
