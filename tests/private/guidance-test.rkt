#lang racket/base

(require rackunit
         "../../private/guidance.rkt"
         (only-in "../../private/model.rkt"
                  tokenize
                  tokenizer)
         (only-in "../../private/regex.rkt"
                  make-regex-vocabulary
                  parse-regex-search-program))

(define vocab
  (list " yes" " no" " refund" " TODO" " cat" " small"))

(define vocab-vector (list->vector vocab))

(define (token-id text)
  (let loop ([id 0])
    (cond
      [(= id (vector-length vocab-vector))
       (error 'token-id "missing token text: ~s" text)]
      [(equal? (vector-ref vocab-vector id) text) id]
      [else (loop (add1 id))])))

(define tok
  (tokenizer
   #:vocab-size (vector-length vocab-vector)
   #:token-ref (lambda (id) (vector-ref vocab-vector id))
   #:tokenize
   (lambda (text)
     (list (token-id text)))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref vocab-vector id)) ids)))))

(define (compile program)
  (compile-guidance program
                    (lambda (text) (tokenize tok text))
                    (make-regex-vocabulary vocab-vector)))

(module+ test
  (test-case "score wraps a hard literal program"
    (define g
      (compile
       (make-score-program 5.0 (make-lit-program " yes"))))
    (define st (guidance-step g (guidance-initial g) (token-id " yes")))
    (check-true (guidance-accepting? st))
    (check-equal? (guidance-score st) 5.0))

  (test-case "text can mix rank reward and hard ban observers"
    (define g
      (compile
       (make-text-program
        1
        (list (make-rank-observer 3.0 " refund")
              (make-ban-observer " TODO")))))
    (define rewarded (guidance-step g (guidance-initial g) (token-id " refund")))
    (define banned (guidance-step g (guidance-initial g) (token-id " TODO")))
    (check-true (guidance-accepting? rewarded))
    (check-equal? (guidance-score rewarded) 3.0)
    (check-true (guidance-dead? banned)))

  (test-case "text can mix regex reward and regex hard ban observers"
    (define g
      (compile
       (make-text-program
        1
        (list (make-rx-rank-observer 4.0 (parse-regex-search-program "(?i)refund"))
              (make-rx-ban-observer (parse-regex-search-program "(?i)todo"))))))
    (define rewarded (guidance-step g (guidance-initial g) (token-id " refund")))
    (define banned (guidance-step g (guidance-initial g) (token-id " TODO")))
    (check-true (guidance-accepting? rewarded))
    (check-equal? (guidance-score rewarded) 4.0)
    (check-true (guidance-dead? banned)))

  (test-case "seq preserves value and accumulated guidance score"
    (define g
      (compile
       (make-seq-program
        (list (make-score-program 2.0 (make-lit-program " yes"))
              (make-pure-program 'ok)))))
    (define st (guidance-step g (guidance-initial g) (token-id " yes")))
    (check-true (guidance-accepting? st))
    (check-equal? (guidance-value st) 'ok)
    (check-equal? (guidance-score st) 2.0))

  (test-case "bind selects a value and continues with another program"
    (define g
      (compile
       (make-bind-program
        (make-seq-program (list (make-lit-program " small")
                                (make-pure-program 'small)))
        (lambda (value)
          (case value
            [(small) (make-lit-program " cat")]
            [else (error 'guidance-test "unexpected value: ~a" value)])))))
    (define st1 (guidance-step g (guidance-initial g) (token-id " small")))
    (check-false (guidance-accepting? st1))
    (define st2 (guidance-step g st1 (token-id " cat")))
    (check-true (guidance-accepting? st2)))

  (test-case "repeat does not accept a partially started invalid item"
    (define g (compile (make-repeat-program 1 3 (make-lit-program " yes"))))
    (define boundary (guidance-step g (guidance-initial g) (token-id " yes")))
    (check-true (guidance-accepting? boundary))
    (define invalid (guidance-step g boundary (token-id " no")))
    (check-true (guidance-dead? invalid)))

  (test-case "repeat rejects nullable items"
    (check-exn #rx"nullable repeated programs"
               (lambda () (compile (make-repeat-program 0 2 (make-pure-program 'x)))))))
