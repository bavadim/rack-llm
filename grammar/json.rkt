#lang racket/base

(require "combinators.rkt"
         "../grammar.rkt")

(provide (struct-out json-field)
         json-object
         json-array
         json-string
         json-number
         json-boolean
         json-enum)

(struct json-field
  (name grammar required?)
  #:transparent)

(define (json-object fields)
  (seq (lit "{")
       (fields-expr fields #t)
       (lit "}")))

(define (json-array item min-count max-count)
  (seq (lit "[")
       (sep-by item (lit ",") min-count max-count)
       (lit "]")))

(define (json-string #:max-chars [max-chars 16]
                     #:pattern [pattern #f])
  (seq (lit "\"")
       (regex (or pattern (format "[A-Za-z0-9_ -]{0,~a}" max-chars)))
       (lit "\"")))

(define json-number
  (regex "-?[0-9]+(\\.[0-9]+)?"))

(define json-boolean
  (choice (lit "true") (lit "false")))

(define (json-enum values)
  (apply choice (map (lambda (value) (lit (json-literal-string value))) values)))

(define (fields-expr fields first?)
  (cond
    [(null? fields) (seq)]
    [else
     (define field (car fields))
     (define present
       (seq (if first? (seq) (lit ","))
            (lit (json-literal-string (json-field-name field)))
            (lit ":")
            (capture (string->symbol (json-field-name field))
                     (json-field-grammar field))
            (fields-expr (cdr fields) #f)))
     (cond
       [(json-field-required? field) present]
       [else (choice present (fields-expr (cdr fields) first?))])]))

(define (json-literal-string value)
  (string-append "\""
                 (regexp-replace* #rx"\"" (regexp-replace* #rx"\\\\" value "\\\\\\\\") "\\\\\"")
                 "\""))
