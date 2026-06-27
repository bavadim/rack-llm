#lang racket

(require racket/stream
         rack-llm
         rack-llm/providers/mock
         rack-llm/providers/provider-v2
         rack-llm/rules)

(random-seed 202)

(define provider
  (make-mock-provider
   #:vocab '("bad" "ok")
   #:default-logits '#(0.0 -0.2)))

(define ok-rule
  (rule 'must-be-ok
        "candidate must be ok"
        'candidate
        (lambda (candidate)
          (if (equal? candidate "ok")
              (accept)
              (reject #:message "not ok")))))

(define (accepted? text)
  (acceptance-report-hard-passed?
   (run-rules
    (acceptance-input text (list (hard ok-rule))))))

(define selected
  (for/first ([program (in-stream (eval (provider->token-oracle provider)
                                        (list (assistant (gen 1)))))]
              #:when (accepted? (message->string (car program))))
    (message->string (car program))))

(displayln selected)
