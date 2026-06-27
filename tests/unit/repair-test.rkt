#lang racket/base

(require rackunit
         rack-llm
         rack-llm/repair
         rack-llm/rules/threshold-acceptance)

(define repair-tests
  (test-suite
   "repair prompt mode"

   (test-case "repair transcript appends structured diagnostic prompt"
     (define transcript
       (list (user (lit "Write exactly 50 words."))))
     (define decision
       (acceptance-decision #f
                            #t
                            0.1
                            (hash 'word-count 0.1)
                            (list "word_count_split: expected 50 words, got 61"
                                  "forbidden_phrase_regex: found banned phrase")))
     (define repaired
       (make-repair-transcript transcript "bad candidate" decision))
     (check-equal? (length repaired) 2)
     (define repair-text (message->string (last-message repaired)))
     (check-true (regexp-match? #rx"Previous candidate was rejected" repair-text))
     (check-true (regexp-match? #rx"word_count_split" repair-text))
     (check-true (regexp-match? #rx"Regenerate a corrected answer" repair-text)))

   (test-case "repair config is explicit and disabled can be represented"
     (define cfg (repair-config #f 0 0))
     (check-false (repair-config-enabled? cfg)))))

(define (last-message messages)
  (if (null? (cdr messages))
      (car messages)
      (last-message (cdr messages))))

(module+ test
  (require rackunit/text-ui)
  (run-tests repair-tests))
