#lang racket/base

(require rackunit
         racket/list
         racket/set
         racket/string
         rack-llm)

(define (make-sequence-model outputs)
  (define remaining (box outputs))
  (make-chat-model
   (lambda (messages #:max-tokens [max-tokens #f]
                     #:temperature [temperature #f]
                     #:stop [stop #f]
                     #:extra [extra (hash)])
     (define xs (unbox remaining))
     (cond
       [(null? xs) "fallback"]
       [else
        (set-box! remaining (cdr xs))
        (car xs)]))
   #:name "mock"))

(define-grammar (label-g)
  (gen #:as 'label
       #:regex #px"[^\n]{1,64}"
       #:max-tokens 12))

(define bad-endings (set "и" "или" "но" "для" "с" "в" "на"))

(define (no-dangling-ending ctx cand)
  (define words
    (string-split
     (string-downcase
      (string-trim (candidate-text cand) " .,!?;:"))))
  (cond
    [(null? words) (fail "empty")]
    [(set-member? bad-endings (last words))
     (fail "dangling ending")]
    [else (pass #:score 1.0)]))

(define model
  (make-sequence-model
   (list "и"
         "Удалить {count} файлов")))

(define res
  (run model
       (chat
        (system "test")
        (user "test")
        (assistant
         (best-of (label-g)
                  #:as 'label
                  #:tries 2
                  #:reviewers (list (weighted 1 no-dangling-ending)))))))

(check-equal? (result-ref res 'label) "Удалить {count} файлов")
(check-equal? (result-text res) "Удалить {count} файлов")
