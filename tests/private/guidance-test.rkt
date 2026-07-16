#lang racket/base

(require rackunit
         "../../main.rkt"
         "../../private/domain.rkt"
         "../../private/guidance.rkt"
         "../../private/regex.rkt")

(define pieces (vector "a" "b" "x" "!" "\n"))
(define (encode text)
  (for/list ([ch (in-string text)])
    (or (for/first ([piece (in-vector pieces)] [i (in-naturals)]
                    #:when (string=? piece (string ch))) i)
        (error 'encode "unknown character ~s" ch))))
(define vocabulary (make-regex-vocabulary pieces))
(define (compile program) (compile-guidance program encode vocabulary))
(define (run program ids)
  (define guidance (compile program))
  (values guidance
          (for/fold ([state (guidance-initial guidance)]) ([id (in-list ids)])
            (guidance-step guidance state id))))
(define (accepts? program text)
  (define-values (_ state) (run program (encode text)))
  (guidance-accepting? state))

(module+ test
  (test-case "control emits scoped prefer/avoid labels in structural order"
    (define program
      (control (text 4)
               (prefer (ere "ab"))
               (avoid (lit "x"))))
    (define-values (_ state) (run program '(0 1 3)))
    (check-true (guidance-accepting? state))
    (define matches (guidance-weak-matches state))
    (check-equal? (map weak-match-path matches)
                  '("root/control/rule[0]" "root/control/rule[1]"))
    (check-equal? (map weak-match-matched? matches) '(#t #f))
    (check-equal? (map weak-match-start-token matches) '(0 0))
    (check-equal? (map weak-match-end-token matches) '(3 3)))

  (test-case "end-anchored ban blocks only the current scope boundary"
    (define program (control (text 3) (ban (ere "x$"))))
    (define-values (guidance at-x) (run program '(2)))
    (check-false (guidance-accepting? at-x))
    (define extended (guidance-step guidance at-x 0))
    (check-true (guidance-accepting? extended))
    (check-false (guidance-dead? extended)))

  (test-case "unanchored ban is latched immediately"
    (define program (control (text 3) (ban (ere "x"))))
    (define-values (_ state) (run program '(0 2)))
    (check-true (guidance-dead? state)))

  (test-case "text accepts from zero through its bound"
    (define program (text 2))
    (define-values (guidance empty) (run program '()))
    (check-true (guidance-accepting? empty))
    (define full (guidance-step guidance (guidance-step guidance empty 0) 1))
    (check-true (guidance-accepting? full))
    (check-true (guidance-dead? (guidance-step guidance full 0))))

  (test-case "repeat does not accept while another item is partial"
    (define program (repeat 1 2 (seq (list (lit "a") (lit "b")))))
    (define-values (guidance one) (run program '(0 1)))
    (check-true (guidance-accepting? one))
    (define partial (guidance-step guidance one 0))
    (check-false (guidance-accepting? partial))
    (check-true (guidance-accepting? (guidance-step guidance partial 1))))

  (test-case "sequence preserves both accepting and live prefix alternatives"
    (define program
      (seq (list (choice (list (lit "a") (lit "ab"))) (lit "x"))))
    (define-values (guidance at-a) (run program '(0)))
    (define domain (guidance-token-domain guidance at-a))
    (check-true (domain-member? domain 1))
    (check-true (domain-member? domain 2))
    (check-true (accepts? program "ax"))
    (check-true (accepts? program "abx"))
    (check-false (accepts? program "ab")))

  (test-case "nullable and accepting regex prefixes keep every continuation"
    (define nullable
      (seq (list (choice (list (lit "") (lit "a"))) (lit "x"))))
    (check-true (accepts? nullable "x"))
    (check-true (accepts? nullable "ax"))
    (define regex-prefix (seq (list (ere "a(b)?") (lit "x"))))
    (check-true (accepts? regex-prefix "ax"))
    (check-true (accepts? regex-prefix "abx")))

  (test-case "repeat preserves short and long item parses"
    (define program (repeat 1 2 (choice (list (lit "a") (lit "ab")))))
    (define-values (guidance at-a) (run program '(0)))
    (define domain (guidance-token-domain guidance at-a))
    (check-true (domain-member? domain 0))
    (check-true (domain-member? domain 1))
    (for ([text (in-list '("a" "ab" "aa" "aab" "aba" "abab"))])
      (check-true (accepts? program text) text)))

  (test-case "overlapping choice merges weak matches from all accepting branches"
    (define program
      (choice
       (list (control (lit "x") (prefer (lit "x")))
             (control (lit "x") (avoid (lit "x")))
             (control (lit "xa") (prefer (lit "x"))))))
    (define-values (_ state) (run program '(2)))
    (define matches (guidance-weak-matches state))
    (check-equal? (map weak-match-polarity matches) '(prefer avoid))
    (check-equal? (map weak-match-matched? matches) '(#t #t))
    (check-equal? (map weak-match-path matches)
                  '("root/choice[0]/control/rule[0]"
                    "root/choice[1]/control/rule[0]")))

  (test-case "ambiguous repeat preserves distinct weak spans"
    (define program
      (repeat
       1 2
       (choice
        (list (control (lit "a") (prefer (lit "a")))
              (control (lit "aa") (avoid (lit "aa")))))))
    (define-values (_ state) (run program '(0 0)))
    (define matches (guidance-weak-matches state))
    (define spans
      (map (lambda (m) (list (weak-match-polarity m)
                             (weak-match-start-token m)
                             (weak-match-end-token m)))
           matches))
    (check-not-false (member '(prefer 0 1) spans))
    (check-not-false (member '(prefer 1 2) spans))
    (check-not-false (member '(avoid 0 2) spans)))

  (test-case "end-anchored ban blocks only the epsilon continuation"
    (define program
      (seq
       (list (control (choice (list (lit "a") (lit "ab")))
                      (ban (ere "a$")))
             (lit "x"))))
    (define-values (guidance at-a) (run program '(0)))
    (define domain (guidance-token-domain guidance at-a))
    (check-true (domain-member? domain 1))
    (check-false (domain-member? domain 2))
    (check-false (accepts? program "ax"))
    (check-true (accepts? program "abx")))

  (test-case "PWSG profile rejects advanced and ambiguous constructs"
    (check-equal? (validate-pwsg (control (text 4) (prefer (ere "a")))) '())
    (check-not-equal? (validate-pwsg (rx "a+")) '())
    (check-not-equal? (validate-pwsg (seq (list (text 2) (lit "x")))) '())
    (check-not-equal? (validate-pwsg (repeat 1 2 (text 2))) '())))
