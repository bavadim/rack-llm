#lang typed/racket/base

(provide (struct-out expr)
         (struct-out value)
         (struct-out message)
         (struct-out lit)
         (struct-out gen)
         (struct-out select)
         (struct-out generated)
         (struct-out selected)
         Program
         EvaluatedProgram
         LLM
         system
         user
         assistant
         (rename-out [eval-program eval]))

(define-type Program (Listof (message expr)))
(define-type EvaluatedProgram (Listof (message value)))
(define-type LLM (-> EvaluatedProgram (Listof expr) (Listof value)))

(struct expr () #:transparent)
(struct value expr () #:transparent)

(struct: (A) message
  ([role : (U 'system 'user 'assistant)]
   [body : (Listof A)])
  #:transparent)

(struct lit value
  ([value : String])
  #:transparent)

(struct gen expr
  ([max-tokens : Natural])
  #:transparent)

(struct select expr
  ([first : (Listof expr)]
   [rest : (Listof (Listof expr))])
  #:transparent)

(struct generated value
  ([source : gen]
   [text : String])
  #:transparent)

(struct selected value
  ([source : select]
   [choice : (Listof value)])
  #:transparent)

(: system (expr * -> (message expr)))
(define (system . exprs)
  (message 'system exprs))

(: user (expr * -> (message expr)))
(define (user . exprs)
  (message 'user exprs))

(: assistant (expr * -> (message expr)))
(define (assistant . exprs)
  (message 'assistant exprs))

(: eval-program (-> LLM Program EvaluatedProgram))
(define (eval-program complete messages)
  (define-predicate fixed-body? (Listof value))
  (let loop ([remaining : Program messages]
             [transcript : EvaluatedProgram '()]
             [acc : EvaluatedProgram '()])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define msg (car remaining))
       (define body (message-body msg))
       (define body*
         (if (fixed-body? body)
             body
             (complete transcript body)))
       (define msg* : (message value) (message (message-role msg) body*))
       (loop (cdr remaining)
             (append transcript (list msg*))
             (cons msg* acc))])))
