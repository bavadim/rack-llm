#lang typed/racket

(require typed/racket/stream)
(require typed/racket/maybe)

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

(: eval-program (-> LLM Program (Streamof EvaluatedProgram)))
(define (eval-program llm program)
	(define-predicate is-program? (Listof value))
	(let loop ([remaining : Program program]
						 [transcript : EvaluatedProgram '()]
						 [acc : EvaluatedProgram '()])
		(cond
			[(null? remaining) (
				(stream-cons (reverse acc) (eval-program llm program)))]
			[else
				(let* ( [msg (car remaining)]
								[body (message-body msg)]
								[body* (if (is-program? body) body (llm transcript body))]
								[msg* : (message value) (message (message-role msg) body*)])
					(loop (cdr remaining)
						 (append transcript (list msg*))
						 (cons msg* acc)))])))

(define-type Check (-> EvaluatedProgram Boolean))

(: find-program (-> LLM Program (Listof Check) (Maybe EvaluatedProgram)))
(define (find-program llm program checks)
  (for/first ([variant : EvaluatedProgram (stream-take (eval-program llm program) 10)]
              #:when (andmap (lambda ([check : Check]) (check variant)) checks))
    variant))