#lang typed/racket/base

(require racket/list
         "../grammar.rkt")

(provide seq
         choice
         optional
         zero-or-more
         one-or-more
         repeat
         sep-by
         regex
         capture
         grammar-accepts?
         grammar->strings)

(define default-repeat-max : Natural 8)

(: seq (expr * -> expr))
(define (seq . exprs)
  (seq-expr exprs))

(: choice (Any * -> expr))
(define (choice . args)
  (choice-expr (normalize-choice-args args)))

(: optional (-> expr expr))
(define (optional g)
  (optional-expr g))

(: zero-or-more (-> expr expr))
(define (zero-or-more g)
  (repeat-expr g 0 default-repeat-max))

(: one-or-more (-> expr expr))
(define (one-or-more g)
  (repeat-expr g 1 default-repeat-max))

(: repeat (-> expr Natural Natural expr))
(define (repeat g min-count max-count)
  (repeat-expr g min-count max-count))

(: sep-by (-> expr expr Natural Natural expr))
(define (sep-by item separator min-count max-count)
  (sep-by-expr item separator min-count max-count))

(: regex (-> String expr))
(define (regex pattern)
  (regex-expr pattern))

(: capture (-> Symbol expr expr))
(define (capture name g)
  (capture-expr name g))

(: grammar-accepts? (-> (U Grammar expr) String Boolean))
(define (grammar-accepts? g text)
  (define m (compile-matcher g))
  (matcher-accepting?
   (matcher-advance m (matcher-start m) text)))

(: grammar->strings (->* ((U Grammar expr)) (#:max-depth Natural) (Listof String)))
(define (grammar->strings g #:max-depth [max-depth 4])
  (remove-duplicates
   (filter (lambda ([s : String]) (<= (string-length s) max-depth))
           (enumerate-target g max-depth))))

(: normalize-choice-args (-> (Listof Any) (Listof expr)))
(define (normalize-choice-args args)
  (cond
    [(null? args) '()]
    [(and (= (length args) 2)
          (expr-list-value? (cadr args)))
     (cons (as-expr (car args)) (as-expr-list (cadr args)))]
    [else (map as-expr args)]))

(: as-expr (-> Any expr))
(define (as-expr value)
  (assert value expr?))

(: expr-list-value? (-> Any Boolean))
(define (expr-list-value? value)
  (and (list? value)
       (andmap expr? value)))

(: as-expr-list (-> Any (Listof expr)))
(define (as-expr-list value)
  (cond
    [(expr-list-value? value) (cast value (Listof expr))]
    [else (error 'choice "expected a list of grammar expressions: ~e" value)]))

(: enumerate-target (-> (U Grammar expr) Natural (Listof String)))
(define (enumerate-target g max-depth)
  (if (list? g)
      (enumerate-seq g max-depth)
      (enumerate-expr g max-depth)))

(: enumerate-expr (-> expr Natural (Listof String)))
(define (enumerate-expr g max-depth)
  (cond
    [(lit? g) (list (lit-value g))]
    [(seq-expr? g) (enumerate-seq (seq-expr-items g) max-depth)]
    [(choice-expr? g)
     (append-map (lambda ([option : expr]) (enumerate-expr option max-depth))
                 (choice-expr-options g))]
    [(optional-expr? g)
     (cons "" (enumerate-expr (optional-expr-item g) max-depth))]
    [(repeat-expr? g)
     (enumerate-repeat (repeat-expr-item g)
                       (repeat-expr-min g)
                       (repeat-expr-max g)
                       max-depth)]
    [(sep-by-expr? g)
     (enumerate-sep-by (sep-by-expr-item g)
                       (sep-by-expr-separator g)
                       (sep-by-expr-min g)
                       (sep-by-expr-max g)
                       max-depth)]
    [(regex-expr? g) (enumerate-regex-fragment (regex-expr-pattern g))]
    [(capture-expr? g) (enumerate-expr (capture-expr-item g) max-depth)]
    [(select? g)
     (append-map (lambda ([body : Choice]) (enumerate-seq body max-depth))
                 (cons (select-first g) (select-rest g)))]
    [else '("")]))

(: enumerate-seq (-> Grammar Natural (Listof String)))
(define (enumerate-seq exprs max-depth)
  (foldl
   (lambda ([g : expr] [acc : (Listof String)])
     (for*/list : (Listof String) ([prefix (in-list acc)]
                                   [suffix (in-list (enumerate-expr g max-depth))]
                                   #:when (<= (+ (string-length prefix)
                                                 (string-length suffix))
                                              max-depth))
       (string-append prefix suffix)))
   (list "")
   exprs))

(: enumerate-repeat (-> expr Natural Natural Natural (Listof String)))
(define (enumerate-repeat g min-count max-count max-depth)
  (append*
   (for/list : (Listof (Listof String)) ([count (in-range min-count (add1 max-count))])
     (define n (assert count exact-nonnegative-integer?))
     (enumerate-repeat-count g n max-depth))))

(: enumerate-repeat-count (-> expr Natural Natural (Listof String)))
(define (enumerate-repeat-count g count max-depth)
  (if (zero? count)
      (list "")
      (enumerate-seq (make-list count g) max-depth)))

(: enumerate-sep-by (-> expr expr Natural Natural Natural (Listof String)))
(define (enumerate-sep-by item separator min-count max-count max-depth)
  (append*
   (for/list : (Listof (Listof String)) ([count (in-range min-count (add1 max-count))])
     (define n (assert count exact-nonnegative-integer?))
     (cond
       [(zero? n) (list "")]
       [else
        (enumerate-seq
         (let loop : Grammar ([remaining : Natural n])
           (cond
             [(= remaining 1) (list item)]
             [else
              (cons item
                    (cons separator
                          (loop (assert (sub1 remaining)
                                        exact-nonnegative-integer?))))]))
         max-depth)]))))

(: enumerate-regex-fragment (-> String (Listof String)))
(define (enumerate-regex-fragment pattern)
  (cond
    [(equal? pattern "[0-9]") (map number->string (range 10))]
    [(equal? pattern "[0-9]+") (map number->string (range 10))]
    [(equal? pattern "[a-z]+") '("a" "b")]
    [(equal? pattern "[A-Za-z]+") '("a" "B")]
    [(equal? pattern "[A-Za-z0-9_ -]*") '("" "a" "A" "0" "a b")]
    [else '("")]))
