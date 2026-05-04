#lang info

(define collection "rack-llm")
(define deps
  '("base"
    "net-lib"
    "json-lib"))
(define build-deps
  '("rackunit-lib"
    "scribble-lib"
    "racket-doc"))
(define scribblings
  '(("scribblings/rack-llm.scrbl" ())))
(define pkg-desc "Grammar-first LLM programming primitives for Racket")
(define version "0.1.0")
(define license 'MIT)
