#lang typed/racket/base

(require racket/list)

(provide (struct-out completed-message)
         (struct-out chat)
         (struct-out message)
         (struct-out lit)
         (struct-out seq)
         (struct-out gen)
         (struct-out select)
         (struct-out generated)
         (struct-out selected)
         Role
         Part
         Completer
         message?
         part?
         system
         user
         assistant
         value
         (rename-out [eval-chat eval])
         grammar->messages)

(define-type Role (U 'system 'user 'assistant))
(define-type Part (U lit seq gen select generated selected))
(define-type Completer (-> (Listof completed-message) Part Part))
(define-type EvalValue (U String Part))

(struct completed-message
  ([role : Role]
   [content : String])
  #:transparent)

(struct chat
  ([messages : (Listof message)])
  #:transparent)

(struct message
  ([role : Role]
   [body : Part])
  #:transparent)

(struct lit
  ([value : String])
  #:transparent)

(struct seq
  ([parts : (Listof Part)])
  #:transparent)

(struct gen
  ([max-tokens : Natural])
  #:transparent)

(struct select
  ([first : Part]
   [rest : (Listof Part)])
  #:transparent)

(struct generated
  ([source : gen]
   [text : String])
  #:transparent)

(struct selected
  ([source : select]
   [choice : Part])
  #:transparent)

(: part? (-> Any Boolean))
(define (part? v)
  (or (lit? v)
      (seq? v)
      (gen? v)
      (select? v)
      (generated? v)
      (selected? v)))

(: system (Part * -> message))
(define (system . parts)
  (message 'system (parts->body parts)))

(: user (Part * -> message))
(define (user . parts)
  (message 'user (parts->body parts)))

(: assistant (Part * -> message))
(define (assistant . parts)
  (message 'assistant (parts->body parts)))

(: grammar->messages (-> chat (Listof completed-message)))
(define (grammar->messages c)
  (for/list : (Listof completed-message) ([msg (in-list (chat-messages c))])
    (completed-message (message-role msg)
                  (part->static-string (message-body msg)))))

(: value (-> chat Any EvalValue))
(define (value c node)
  (or (find-value-in-messages (chat-messages c) node)
      (error 'value "no value recorded for node: ~e" node)))

(: eval-chat (-> Completer chat chat))
(define (eval-chat complete c)
  (define-values (messages _transcript)
    (eval-messages complete (chat-messages c) '()))
  (chat messages))

(: eval-messages
   (-> Completer (Listof message) (Listof completed-message)
       (Values (Listof message) (Listof completed-message))))
(define (eval-messages complete messages transcript)
  (cond
    [(null? messages) (values '() transcript)]
    [else
     (define msg (car messages))
     (define body (message-body msg))
     (define body*
       (if (static-part? body)
           body
           (complete transcript body)))
     (define content (part->static-string body*))
     (define msg* (message (message-role msg) body*))
     (define transcript* (append transcript (list (completed-message (message-role msg) content))))
     (define-values (rest-messages transcript**)
       (eval-messages complete (cdr messages) transcript*))
     (values (cons msg* rest-messages) transcript**)]))

(: parts->body (-> (Listof Part) Part))
(define (parts->body parts)
  (cond
    [(null? parts) (lit "")]
    [(null? (cdr parts)) (car parts)]
    [else (seq parts)]))

(: static-part? (-> Part Boolean))
(define (static-part? part)
  (cond
    [(lit? part) #t]
    [(seq? part) (andmap static-part? (seq-parts part))]
    [(gen? part) #f]
    [(select? part) #f]
    [(generated? part) #t]
    [(selected? part) (static-part? (selected-choice part))]))

(: part->static-string (-> Part String))
(define (part->static-string part)
  (cond
    [(lit? part) (lit-value part)]
    [(seq? part) (apply string-append (map part->static-string (seq-parts part)))]
    [(generated? part) (generated-text part)]
    [(selected? part) (part->static-string (selected-choice part))]
    [(gen? part) (error 'grammar->messages "grammar contains generated nodes")]
    [(select? part) (error 'grammar->messages "grammar contains selection nodes")]))

(: find-value-in-messages (-> (Listof message) Any (Option EvalValue)))
(define (find-value-in-messages messages node)
  (let loop ([messages : (Listof message) messages])
    (cond
      [(null? messages) #f]
      [else
       (or (find-value-in-part (message-body (car messages)) node)
           (loop (cdr messages)))])))

(: find-value-in-parts (-> (Listof Part) Any (Option EvalValue)))
(define (find-value-in-parts parts node)
  (let loop ([parts : (Listof Part) parts])
    (cond
      [(null? parts) #f]
      [else
       (or (find-value-in-part (car parts) node)
           (loop (cdr parts)))])))

(: find-value-in-part (-> Part Any (Option EvalValue)))
(define (find-value-in-part part node)
  (cond
    [(lit? part) #f]
    [(seq? part) (find-value-in-parts (seq-parts part) node)]
    [(gen? part) #f]
    [(select? part) #f]
    [(generated? part)
     (if (eq? (generated-source part) node)
         (generated-text part)
         #f)]
    [(selected? part)
     (or (and (eq? (selected-source part) node)
              (selected-choice part))
         (find-value-in-part (selected-choice part) node))]))
