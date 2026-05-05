#lang racket/base

(require racket/port
         racket/runtime-path
         rackunit)

(define-runtime-path main-source "../../main.rkt")
(define-runtime-path llama-cpp-source "../../backends/llama-cpp.rkt")

(define (source path)
  (call-with-input-file path port->string))

(define (first-line path)
  (call-with-input-file path read-line))

(define (count-matches rx text)
  (length (regexp-match* rx text)))

(define functional-core-forbidden-patterns
  (list
   (cons #px"\\bset!\\b" "set!")
   (cons #px"\\bbox\\b" "box")
   (cons #rx"set-box!" "set-box!")
   (cons #px"\\bmake-hash(eq)?\\b" "mutable hash constructor")
   (cons #rx"hash-set!" "hash-set!")
   (cons #rx"vector-set!" "vector-set!")
   (cons #rx"set-mcar!" "set-mcar!")
   (cons #rx"set-mcdr!" "set-mcdr!")
   (cons #px"#:mutable\\b" "#:mutable")))

(define source-policy
  (test-suite
   "source policy"

   (test-case "functional core has no local mutation"
     (define text (source main-source))
     (for ([entry (in-list functional-core-forbidden-patterns)])
       (check-equal? (count-matches (car entry) text)
                     0
                     (format "unexpected ~a in main.rkt" (cdr entry)))))

   (test-case "production modules use Typed Racket"
     (check-equal? (first-line main-source) "#lang typed/racket/base")
     (check-equal? (first-line llama-cpp-source) "#lang typed/racket/base"))

   (test-case "public structs stay immutable"
     (check-equal? (count-matches #px"#:mutable\\b" (source main-source)) 0)
     (check-equal? (count-matches #px"#:mutable\\b" (source llama-cpp-source)) 0))

   (test-case "llama.cpp backend mutation is limited to grammar compilation state"
     (define text (source llama-cpp-source))
     (check-equal? (count-matches #rx"\\(set!" text) 2)
     (check-equal? (count-matches #px"\\bmake-hasheq\\b" text) 2)
     (check-equal? (count-matches #rx"hash-set!" text) 2)
     (check-equal? (count-matches #px"\\bbox\\b" text) 0))))

(module+ test
  (require rackunit/text-ui)
  (run-tests source-policy))
