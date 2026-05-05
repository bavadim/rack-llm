#lang typed/racket/base

(require racket/list
         racket/string)

(provide (struct-out chat-model)
         (struct-out request)
         (struct-out chat-message)
         chat?
         message?
         part?
         grammar?
         make-chat-model
         model-complete
         chat
         grammar
         seq
         system
         user
         assistant
         gen
         select
         (rename-out [eval-chat eval])
         grammar->messages)

(define-type Role (U 'system 'user 'assistant))
(define-type Part (U String seq-node gen-node select-node))

(struct chat-model
  ([name : String]
   [complete : (-> request String)])
  #:transparent)

(struct request
  ([messages : (Listof chat-message)]
   [max-tokens : (Option Natural)]
   [grammar : (Option String)])
  #:transparent)

(struct chat-message
  ([role : Role]
   [content : String])
  #:transparent)

(struct chat-ast
  ([messages : (Listof message)])
  #:transparent
  #:constructor-name make-chat)

(struct message
  ([role : Role]
   [parts : (Listof Part)])
  #:transparent)

(struct seq-node
  ([parts : (Listof Part)])
  #:transparent)

(struct gen-node
  ([max-tokens : Natural])
  #:transparent)

(struct select-node
  ([variants : (Listof Part)])
  #:transparent)

(: make-chat-model (->* ((-> request String)) (#:name String) chat-model))
(define (make-chat-model complete #:name [name "model"])
  (chat-model name complete))

(: model-complete (-> chat-model request String))
(define (model-complete model req)
  ((chat-model-complete model) req))

(: part? (-> Any Boolean))
(define (part? v)
  (or (string? v) (seq-node? v) (gen-node? v) (select-node? v)))

(: grammar? (-> Any Boolean))
(define (grammar? v)
  (or (chat-ast? v) (message? v) (part? v)))

(: chat? (-> Any Boolean))
(define chat? chat-ast?)

(: chat (message * -> chat-ast))
(define (chat . messages)
  (make-chat messages))

(: grammar (message * -> chat-ast))
(define (grammar . messages)
  (make-chat messages))

(: seq (Part * -> seq-node))
(define (seq . parts)
  (seq-node parts))

(: system (Part * -> message))
(define (system . parts)
  (message 'system parts))

(: user (Part * -> message))
(define (user . parts)
  (message 'user parts))

(: assistant (Part * -> message))
(define (assistant . parts)
  (message 'assistant parts))

(: gen (-> Natural gen-node))
(define (gen max-tokens)
  (gen-node max-tokens))

(: select (Part * -> select-node))
(define (select . variants)
  (when (null? variants)
    (error 'select "expected at least one variant"))
  (select-node variants))

(: grammar->messages (-> chat-ast (Listof chat-message)))
(define (grammar->messages g)
  (for/list : (Listof chat-message) ([msg (in-list (chat-ast-messages g))])
    (chat-message (message-role msg)
                  (parts->string (message-parts msg)))))

(: eval-chat (-> chat-model chat-ast chat-ast))
(define (eval-chat model g)
  (define-values (messages _transcript)
    (for/fold ([done : (Listof message) '()]
               [transcript : (Listof chat-message) '()])
              ([msg (in-list (chat-ast-messages g))])
      (define-values (msg* transcript*) (eval-message model msg transcript))
      (values (cons msg* done) transcript*)))
  (make-chat (reverse messages)))

(: eval-message (-> chat-model message (Listof chat-message)
                    (Values message (Listof chat-message))))
(define (eval-message model msg previous-messages)
  (define-values (parts _buffer)
    (eval-parts model (message-parts msg) previous-messages (message-role msg) ""))
  (define msg* (message (message-role msg) (reverse parts)))
  (values msg* (append previous-messages (list (message->chat-message msg*)))))

(: eval-parts (-> chat-model (Listof Part) (Listof chat-message) Role String
                   (Values (Listof Part) String)))
(define (eval-parts model parts previous-messages role buffer)
  (for/fold ([done : (Listof Part) '()]
             [current : String buffer])
            ([part (in-list parts)])
    (define-values (part* current*) (eval-part model part previous-messages role current))
    (values (cons part* done) current*)))

(: eval-part (-> chat-model Part (Listof chat-message) Role String
                 (Values Part String)))
(define (eval-part model part previous-messages role buffer)
  (cond
    [(string? part)
     (values part (string-append buffer part))]
    [(seq-node? part)
     (define-values (parts* buffer*)
       (eval-parts model (seq-node-parts part) previous-messages role buffer))
     (values (seq-node (reverse parts*)) buffer*)]
    [(gen-node? part)
     (define generated
       (string-trim
        (model-complete
         model
         (request (messages-with-buffer previous-messages role buffer)
                  (gen-node-max-tokens part)
                  #f))))
     (values generated (string-append buffer generated))]
    [(select-node? part)
     (define options (map part->select-string (select-node-variants part)))
     (define choice
       (string-trim
        (model-complete
         model
         (request (messages-with-buffer previous-messages role buffer)
                  (apply max 1 (map string-length options))
                  (finite-choice-grammar options)))))
     (define selected (find-selected choice options (select-node-variants part)))
     (unless selected
       (error 'select "model returned value outside constrained variants; output=~e variants=~e"
              choice options))
     (eval-part model selected previous-messages role buffer)]))

(: message->chat-message (-> message chat-message))
(define (message->chat-message msg)
  (chat-message (message-role msg)
                (parts->string (message-parts msg))))

(: parts->string (-> (Listof Part) String))
(define (parts->string parts)
  (apply string-append (map part->finished-string parts)))

(: part->finished-string (-> Part String))
(define (part->finished-string part)
  (cond
    [(string? part) part]
    [(seq-node? part) (parts->string (seq-node-parts part))]
    [(gen-node? part) (error 'grammar->messages "grammar is not finished")]
    [(select-node? part) (error 'grammar->messages "grammar is not finished")]))

(: part->select-string (-> Part String))
(define (part->select-string part)
  (cond
    [(string? part) part]
    [(seq-node? part) (apply string-append (map part->select-string (seq-node-parts part)))]
    [(gen-node? part) (error 'select "variants must be finite text before selection")]
    [(select-node? part) (error 'select "nested unresolved select variants are not allowed")]))

(: messages-with-buffer (-> (Listof chat-message) Role String (Listof chat-message)))
(define (messages-with-buffer previous-messages role buffer)
  (if (string=? buffer "")
      previous-messages
      (append previous-messages (list (chat-message role buffer)))))

(: find-selected (-> String (Listof String) (Listof Part) (Option Part)))
(define (find-selected choice options variants)
  (cond
    [(or (null? options) (null? variants)) #f]
    [(string=? choice (car options)) (car variants)]
    [else (find-selected choice (cdr options) (cdr variants))]))

(: finite-choice-grammar (-> (Listof String) String))
(define (finite-choice-grammar options)
  (format "root ::= ~a" (string-join (map gbnf-string options) " | ")))

(: gbnf-string (-> String String))
(define (gbnf-string s)
  (format "~s" s))
