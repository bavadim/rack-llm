#lang typed/racket/base

(require racket/list)

(provide (struct-out chat-model)
         (struct-out grammar-request)
         (struct-out chat-message)
         (struct-out chat-ast)
         (struct-out message)
         (struct-out lit-node)
         (struct-out seq-node)
         (struct-out gen-node)
         (struct-out select-node)
         (struct-out generated-node)
         (struct-out selected-node)
         Role
         Part
         chat?
         message?
         part?
         make-chat-model
         model-complete
         chat
         lit
         seq
         system
         user
         assistant
         gen
         select
         value
         (rename-out [eval-chat eval])
         grammar->messages)

(define-type Role (U 'system 'user 'assistant))
(define-type Part (U lit-node seq-node gen-node select-node generated-node selected-node))
(define-type EvalValue (U String Part))

(struct chat-model
  ([name : String]
   [complete : (-> grammar-request Part)])
  #:transparent)

(struct grammar-request
  ([messages : (Listof chat-message)]
   [part : Part])
  #:transparent)

(struct chat-message
  ([role : Role]
   [content : String])
  #:transparent)

(struct chat-ast
  ([messages : (Listof message)]
   [values : (Immutable-HashTable Any EvalValue)])
  #:transparent
  #:constructor-name make-chat)

(struct message
  ([role : Role]
   [body : Part])
  #:transparent)

(struct lit-node
  ([value : String])
  #:transparent)

(struct seq-node
  ([parts : (Listof Part)])
  #:transparent)

(struct gen-node
  ([max-tokens : Natural])
  #:transparent)

(struct select-node
  ([first : Part]
   [rest : (Listof Part)])
  #:transparent)

(struct generated-node
  ([source : gen-node]
   [text : String])
  #:transparent)

(struct selected-node
  ([source : select-node]
   [choice : Part])
  #:transparent)

(: make-chat-model (->* ((-> grammar-request Part)) (#:name String) chat-model))
(define (make-chat-model complete #:name [name "model"])
  (chat-model name complete))

(: model-complete (-> chat-model grammar-request Part))
(define (model-complete model req)
  ((chat-model-complete model) req))

(: part? (-> Any Boolean))
(define (part? v)
  (or (lit-node? v)
      (seq-node? v)
      (gen-node? v)
      (select-node? v)
      (generated-node? v)
      (selected-node? v)))

(: chat? (-> Any Boolean))
(define chat? chat-ast?)

(: chat (message * -> chat-ast))
(define (chat . messages)
  (make-chat messages (hasheq)))

(: lit (-> String lit-node))
(define (lit value)
  (lit-node value))

(: seq (Part * -> seq-node))
(define (seq . parts)
  (seq-node parts))

(: system (Part * -> message))
(define (system . parts)
  (message 'system (parts->body parts)))

(: user (Part * -> message))
(define (user . parts)
  (message 'user (parts->body parts)))

(: assistant (Part * -> message))
(define (assistant . parts)
  (message 'assistant (parts->body parts)))

(: gen (-> Natural gen-node))
(define (gen max-tokens)
  (gen-node max-tokens))

(: select (-> Part Part * select-node))
(define (select first . rest)
  (select-node first rest))

(: grammar->messages (-> chat-ast (Listof chat-message)))
(define (grammar->messages c)
  (for/list : (Listof chat-message) ([msg (in-list (chat-ast-messages c))])
    (chat-message (message-role msg)
                  (part->static-string (message-body msg)))))

(: value (-> chat-ast Any EvalValue))
(define (value c node)
  (hash-ref (chat-ast-values c)
            node
            (lambda ()
              (error 'value "no value recorded for node: ~e" node))))

(: eval-chat (-> chat-model chat-ast chat-ast))
(define (eval-chat model c)
  (define-values (messages _transcript values)
    (eval-messages model (chat-ast-messages c) '() (chat-ast-values c)))
  (make-chat messages values))

(: eval-messages
   (-> chat-model (Listof message) (Listof chat-message) (Immutable-HashTable Any EvalValue)
       (Values (Listof message) (Listof chat-message) (Immutable-HashTable Any EvalValue))))
(define (eval-messages model messages transcript valmap)
  (cond
    [(null? messages) (values '() transcript valmap)]
    [else
     (define msg (car messages))
     (define body (message-body msg))
     (define-values (body* valmap*)
       (if (static-part? body)
           (values body valmap)
           (let ([body* (model-complete model (grammar-request transcript body))])
             (values body* (record-values body body* valmap)))))
     (define content (part->static-string body*))
     (define msg* (message (message-role msg) body*))
     (define transcript* (append transcript (list (chat-message (message-role msg) content))))
     (define-values (rest-messages transcript** valmap**)
       (eval-messages model (cdr messages) transcript* valmap*))
     (values (cons msg* rest-messages) transcript** valmap**)]))

(: parts->body (-> (Listof Part) Part))
(define (parts->body parts)
  (cond
    [(null? parts) (lit-node "")]
    [(null? (cdr parts)) (car parts)]
    [else (seq-node parts)]))

(: static-part? (-> Part Boolean))
(define (static-part? part)
  (cond
    [(lit-node? part) #t]
    [(seq-node? part) (andmap static-part? (seq-node-parts part))]
    [(gen-node? part) #f]
    [(select-node? part) #f]
    [(generated-node? part) #t]
    [(selected-node? part) (static-part? (selected-node-choice part))]))

(: part->static-string (-> Part String))
(define (part->static-string part)
  (cond
    [(lit-node? part) (lit-node-value part)]
    [(seq-node? part) (apply string-append (map part->static-string (seq-node-parts part)))]
    [(generated-node? part) (generated-node-text part)]
    [(selected-node? part) (part->static-string (selected-node-choice part))]
    [(gen-node? part) (error 'grammar->messages "grammar contains generated nodes")]
    [(select-node? part) (error 'grammar->messages "grammar contains selection nodes")]))

(: record-values
   (-> Part Part (Immutable-HashTable Any EvalValue) (Immutable-HashTable Any EvalValue)))
(define (record-values source result valmap)
  (cond
    [(and (gen-node? source)
          (generated-node? result)
          (eq? (generated-node-source result) source))
     (hash-set valmap source (generated-node-text result))]
    [(and (select-node? source)
          (selected-node? result)
          (eq? (selected-node-source result) source))
     (record-values-in-selected
      source
      (selected-node-choice result)
      (hash-set valmap source (selected-node-choice result)))]
    [(and (seq-node? source) (seq-node? result))
     (record-values-list (seq-node-parts source) (seq-node-parts result) valmap)]
    [else valmap]))

(: record-values-in-selected
   (-> select-node Part (Immutable-HashTable Any EvalValue) (Immutable-HashTable Any EvalValue)))
(define (record-values-in-selected source choice valmap)
  (let loop ([variants : (Listof Part) (cons (select-node-first source) (select-node-rest source))])
    (cond
      [(null? variants) valmap]
      [else
       (define valmap* (record-values (car variants) choice valmap))
       (if (eq? valmap* valmap)
           (loop (cdr variants))
           valmap*)])))

(: record-values-list
   (-> (Listof Part) (Listof Part) (Immutable-HashTable Any EvalValue)
       (Immutable-HashTable Any EvalValue)))
(define (record-values-list sources results valmap)
  (cond
    [(or (null? sources) (null? results)) valmap]
    [else
     (record-values-list (cdr sources)
                         (cdr results)
                         (record-values (car sources) (car results) valmap))]))
