#lang info

(define collection "rack-llm")
(define deps
  '("base"
    "typed-racket-lib"))
(define build-deps
  '("rackunit-lib"))
(define compile-omit-paths '("experiments"))
(define test-omit-paths '("experiments"))
(define pkg-desc "Exact hard and programmatic weak sequence sampling")
(define version "0.1")
(define license 'MIT)
