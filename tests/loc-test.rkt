#lang racket/base
(require rackunit racket/file racket/path racket/runtime-path)
(define-runtime-path raw-root "..")
(define root (simplify-path raw-root))
(define files
  (append (map (lambda (name) (build-path root name)) '("main.rkt" "backend.rkt" "model-llama-cpp.rkt"))
          (for/list ([path (in-list (directory-list (build-path root "private") #:build? #t))]
                     #:when (regexp-match? #rx"[.]rkt$" (path->string path))) path)))
(define (lines path) (call-with-input-file path (lambda (in) (for/sum ([_ (in-lines in)]) 1))))
(module+ test
  (test-case "all production Racket runtime stays within 1500 physical lines"
    (define counts (for/list ([path files]) (cons (find-relative-path root path) (lines path))))
    (check-true (<= (apply + (map cdr counts)) 1500) (format "LOC by file: ~a" counts))))
