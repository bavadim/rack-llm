#lang racket/base

(require racket/list
         "../grammar.rkt")

(provide (struct-out grammar-diagnostic)
         compile-grammar/check)

(struct grammar-diagnostic
  (code message path)
  #:transparent)

(define (compile-grammar/check g)
  (define diagnostics
    (append (diagnose-expr g '() '())
            (duplicate-capture-diagnostics g)))
  (if (null? diagnostics)
      (compile-matcher g)
      diagnostics))

(define (diagnose-expr g path captures)
  (cond
    [(list? g) (diagnose-list g path captures)]
    [(choice-expr? g)
     (append
      (if (null? (choice-expr-options g))
          (list (grammar-diagnostic
                 'empty-choice
                 "choice must contain at least one option"
                 (reverse path)))
          '())
      (diagnose-list (choice-expr-options g) (cons 0 path) captures))]
    [(repeat-expr? g)
     (append
      (if (> (repeat-expr-min g) (repeat-expr-max g))
          (list (grammar-diagnostic
                 'impossible-repeat
                 "repeat minimum cannot exceed maximum"
                 (reverse path)))
          '())
      (diagnose-expr (repeat-expr-item g) (cons 0 path) captures))]
    [(sep-by-expr? g)
     (append
      (if (> (sep-by-expr-min g) (sep-by-expr-max g))
          (list (grammar-diagnostic
                 'impossible-repeat
                 "sep-by minimum cannot exceed maximum"
                 (reverse path)))
          '())
      (diagnose-expr (sep-by-expr-item g) (cons 0 path) captures)
      (diagnose-expr (sep-by-expr-separator g) (cons 1 path) captures))]
    [(regex-expr? g)
     (if (unsupported-regex? (regex-expr-pattern g))
         (list (grammar-diagnostic
                'unsupported-regex
                "regex lookbehind and backreferences are not supported by the grammar matcher"
                (reverse path)))
         '())]
    [(capture-expr? g)
     (define name (capture-expr-name g))
     (append
      (if (member name captures)
          (list (grammar-diagnostic
                 'duplicate-capture
                 (format "duplicate capture name: ~a" name)
                 (reverse path)))
          '())
      (diagnose-expr (capture-expr-item g) (cons 0 path) (cons name captures)))]
    [(seq-expr? g)
     (diagnose-list (seq-expr-items g) path captures)]
    [(optional-expr? g)
     (diagnose-expr (optional-expr-item g) (cons 0 path) captures)]
    [(select? g)
     (diagnose-list (append (list (select-first g)) (select-rest g)) path captures)]
    [else '()]))

(define (diagnose-list xs path captures)
  (append*
   (for/list ([x (in-list xs)]
              [i (in-naturals)])
     (diagnose-expr x (cons i path) captures))))

(define (unsupported-regex? pattern)
  (or (regexp-match? #px"\\(\\?<=" pattern)
      (regexp-match? #px"\\(\\?<!" pattern)
      (regexp-match? #px"\\\\[1-9]" pattern)))

(define (duplicate-capture-diagnostics g)
  (let loop ([captures (capture-occurrences g '())]
             [seen '()])
    (cond
      [(null? captures) '()]
      [else
       (define name (caar captures))
       (define path (cdar captures))
       (define rest (loop (cdr captures) (cons name seen)))
       (if (member name seen)
           (cons (grammar-diagnostic
                  'duplicate-capture
                  (format "duplicate capture name: ~a" name)
                  path)
                 rest)
           rest)])))

(define (capture-occurrences g path)
  (cond
    [(list? g) (capture-occurrences-list g path)]
    [(capture-expr? g)
     (cons (cons (capture-expr-name g) (reverse path))
           (capture-occurrences (capture-expr-item g) (cons 0 path)))]
    [(seq-expr? g) (capture-occurrences-list (seq-expr-items g) path)]
    [(choice-expr? g) (capture-occurrences-list (choice-expr-options g) (cons 0 path))]
    [(optional-expr? g) (capture-occurrences (optional-expr-item g) (cons 0 path))]
    [(repeat-expr? g) (capture-occurrences (repeat-expr-item g) (cons 0 path))]
    [(sep-by-expr? g)
     (append (capture-occurrences (sep-by-expr-item g) (cons 0 path))
             (capture-occurrences (sep-by-expr-separator g) (cons 1 path)))]
    [(select? g)
     (capture-occurrences-list (append (list (select-first g)) (select-rest g)) path)]
    [else '()]))

(define (capture-occurrences-list xs path)
  (append*
   (for/list ([x (in-list xs)]
              [i (in-naturals)])
     (capture-occurrences x (cons i path)))))
