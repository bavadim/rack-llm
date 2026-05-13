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

;; Predicate layer

(define-type Check (-> EvaluatedProgram Boolean))
(define-type Checks (Listof Check))

(: checked-programs (-> Checks EvaluatedProgramStream EvaluatedProgramStream))
(define (checked-programs checks variants)
  (stream-filter
   (lambda ([variant : EvaluatedProgram])
     (andmap (lambda ([c : Check]) (c variant)) checks))
   variants))

(: first-satisfying (-> Natural Checks EvaluatedProgramStream (U EvaluatedProgram #f)))
(define (first-satisfying limit checks variants)
  (stream-first-option
   (checked-programs checks
                     (stream-take variants limit))))

(: find-program (-> TokenOracle Program Checks (U EvaluatedProgram #f)))
(define (find-program oracle program checks)
  (first-satisfying 10 checks (eval-program oracle program)))
