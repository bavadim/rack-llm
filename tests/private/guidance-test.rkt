#lang racket/base

(require rackunit
         "../../main.rkt"
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

  (test-case "text accepts from zero through its bound and then becomes terminal"
    (define program (text 2))
    (define-values (guidance empty) (run program '()))
    (check-true (guidance-accepting? empty))
    (check-false (guidance-terminal? guidance empty))
    (define full (guidance-step guidance (guidance-step guidance empty 0) 1))
    (check-true (guidance-accepting? full))
    (check-true (guidance-terminal? guidance full))
    (check-true (guidance-dead? (guidance-step guidance full 0))))

  (test-case "repeat does not accept while another item is partial"
    (define program (repeat 1 2 (seq (list (lit "a") (lit "b")))))
    (define-values (guidance one) (run program '(0 1)))
    (check-true (guidance-accepting? one))
    (define partial (guidance-step guidance one 0))
    (check-false (guidance-accepting? partial))
    (check-true (guidance-accepting? (guidance-step guidance partial 1))))

  (test-case "PWSG profile rejects advanced and ambiguous constructs"
    (check-true (pwsg-compatible? (control (text 4) (prefer (ere "a")))))
    (check-false (pwsg-compatible? (rx "a+")))
    (check-false (pwsg-compatible? (seq (list (text 2) (lit "x")))))
    (check-false (pwsg-compatible? (repeat 1 2 (text 2))))))
