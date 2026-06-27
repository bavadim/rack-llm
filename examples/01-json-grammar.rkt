#lang racket

(require racket/stream
         rack-llm
         rack-llm/providers/mock
         rack-llm/providers/provider-v2)

(random-seed 101)

(define provider
  (make-mock-provider
   #:vocab '("{\"status\":\"ok\"}")
   #:default-logits '#(0.0)))

(define program
  (stream-first
   (eval (provider->token-oracle provider)
         (list (assistant (gen 1))))))

(displayln (message->string (car program)))
