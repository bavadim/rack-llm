#lang racket/base

(require racket/port
         racket/runtime-path
         rackunit)

(define-runtime-path main-source "../../main.rkt")
(define-runtime-path common-source "../../common-combinators.rkt")
(define-runtime-path grammar-source "../../grammar.rkt")
(define-runtime-path sampler-source "../../sampler.rkt")
(define-runtime-path llama-cpp-source "../../backends/llama-cpp.rkt")
(define-runtime-path openai-responses-source "../../backends/openai-responses.rkt")

(define production-sources
  (list main-source
        common-source
  grammar-source
  sampler-source
  llama-cpp-source
  openai-responses-source))

(define functional-core-sources
  (list main-source
        common-source
        grammar-source
        sampler-source))

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
     (for ([path (in-list functional-core-sources)])
       (define text (source path))
       (for ([entry (in-list functional-core-forbidden-patterns)])
         (check-equal? (count-matches (car entry) text)
                       0
                       (format "unexpected ~a in ~a" (cdr entry) path)))))

   (test-case "production modules use Typed Racket"
     (for ([path (in-list production-sources)])
       (check-equal? (first-line path) "#lang typed/racket/base")))

   (test-case "public structs stay immutable"
     (for ([path (in-list production-sources)])
       (check-equal? (count-matches #px"#:mutable\\b" (source path)) 0)))

     (test-case "llama.cpp backend has no local mutation"
       (define text (source llama-cpp-source))
       (check-equal? (count-matches #rx"\\(set!" text) 0)
       (check-equal? (count-matches #px"\\bmake-hasheq\\b" text) 0)
       (check-equal? (count-matches #rx"hash-set!" text) 0)
       (check-equal? (count-matches #px"\\bbox\\b" text) 0))

     (test-case "OpenAI Responses backend has no local mutation"
       (define text (source openai-responses-source))
       (check-equal? (count-matches #rx"\\(set!" text) 0)
       (check-equal? (count-matches #px"\\bmake-hasheq\\b" text) 0)
       (check-equal? (count-matches #rx"hash-set!" text) 0)
       (check-equal? (count-matches #px"\\bbox\\b" text) 0))))

(module+ test
  (require rackunit/text-ui)
  (run-tests source-policy))
