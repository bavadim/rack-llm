#lang typed/racket/base

(require typed/racket/stream
         "common-combinators.rkt"
         "grammar.rkt"
         "sampler.rkt")

(provide (struct-out expr)
         (struct-out value)
         (struct-out message)
         (struct-out lit)
         (struct-out gen)
         (struct-out select)
         (struct-out generated)
         (struct-out selected)
         (struct-out token-candidate)
         Program
         EvaluatedProgram
         TokenOracle
         system
         user
         assistant
         value->string
         body->string
         message->string
         (rename-out [eval-program eval]))

;; Public program semantics

(define empty-transcript : EvaluatedProgram '())

(: eval-program (-> TokenOracle Program EvaluatedProgramStream))
(define (eval-program oracle program)
  (stream-foldM (lambda ([transcript : EvaluatedProgram] [msg : (message expr)])
                  (message-step oracle transcript msg))
                empty-transcript
                program))

(: message-step (-> TokenOracle EvaluatedProgram (message expr) EvaluatedProgramStream))
(define (message-step oracle transcript msg)
  (define role (message-role msg))
  (stream-map
   (lambda ([body : EvaluatedBody])
     (append transcript (list (message role body))))
   (message-bodies oracle transcript msg)))

(: message-bodies (-> TokenOracle EvaluatedProgram (message expr) EvaluatedBodyStream))
(define (message-bodies oracle transcript msg)
  (define body (message-body msg))
  (if (evaluated-body? body)
      (list body)
      (decode-body oracle transcript body)))

(: value->string (-> value String))
(define (value->string v)
  (cond
    [(lit? v) (lit-value v)]
    [(generated? v) (generated-text v)]
    [(selected? v) (body->string (selected-choice v))]
    [else (error 'rack-llm "unsupported evaluated value: ~e" v)]))

(: body->string (-> EvaluatedBody String))
(define (body->string body)
  (apply string-append (map value->string body)))

(: message->string (-> (message value) String))
(define (message->string msg)
  (body->string (message-body msg)))
