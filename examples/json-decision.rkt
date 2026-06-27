#lang racket/base

(require json
         rack-llm/grammar/combinators
         rack-llm/grammar/json)

(define decision-grammar
  (json-object
   (list (json-field "status" (json-enum '("ok" "error")) #t)
         (json-field "retry" json-boolean #t)
         (json-field "reason" (json-string #:max-chars 12) #f))))

(define sample "{\"status\":\"ok\",\"retry\":false,\"reason\":\"done\"}")

(unless (grammar-accepts? decision-grammar sample)
  (error 'json-decision "sample JSON was rejected"))

(define parsed (string->jsexpr sample))

(unless (equal? (hash-ref parsed 'status) "ok")
  (error 'json-decision "unexpected parsed status: ~s" parsed))

(displayln "{\"status\":\"ok\"}")
