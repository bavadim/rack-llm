#lang typed/racket/base

(provide (struct-out part)
         (struct-out fixed-part)
         (struct-out message)
         (struct-out lit)
         (struct-out gen)
         (struct-out select)
         (struct-out generated)
         (struct-out selected)
         Role
         Body
         FixedBody
         Message
         FixedMessage
         Chat
         FixedChat
         Completer
         system
         user
         assistant
         fixed-body->string
         (rename-out [eval-chat eval]))

(define-type Role (U 'system 'user 'assistant))
(define-type Body (Listof part))
(define-type FixedBody (Listof fixed-part))
(define-type Message (message part))
(define-type FixedMessage (message fixed-part))
(define-type Chat (Listof Message))
(define-type FixedChat (Listof FixedMessage))
(define-type Completer (-> FixedChat Body FixedBody))

(struct part () #:transparent)
(struct fixed-part part () #:transparent)

(struct: (A) message
  ([role : Role]
   [body : (Listof A)])
  #:transparent)

(struct lit fixed-part
  ([value : String])
  #:transparent)

(struct gen part
  ([max-tokens : Natural])
  #:transparent)

(struct select part
  ([first : Body]
   [rest : (Listof Body)])
  #:transparent)

(struct generated fixed-part
  ([source : gen]
   [text : String])
  #:transparent)

(struct selected fixed-part
  ([source : select]
   [choice : FixedBody])
  #:transparent)

(: system (part * -> Message))
(define (system . parts)
  (message 'system parts))

(: user (part * -> Message))
(define (user . parts)
  (message 'user parts))

(: assistant (part * -> Message))
(define (assistant . parts)
  (message 'assistant parts))

(: fixed-part->string (-> fixed-part String))
(define (fixed-part->string part)
  (cond
    [(lit? part) (lit-value part)]
    [(generated? part) (generated-text part)]
    [(selected? part) (fixed-body->string (selected-choice part))]
    [else (error 'fixed-part->string "unsupported fixed part: ~e" part)]))

(: fixed-body->string (-> FixedBody String))
(define (fixed-body->string body)
  (apply string-append (map fixed-part->string body)))

(: eval-chat (-> Completer Chat FixedChat))
(define (eval-chat complete messages)
  (let loop ([remaining : Chat messages]
             [transcript : FixedChat '()]
             [acc : FixedChat '()])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define msg (car remaining))
       (define body (message-body msg))
       (define body*
         (let ([fixed (body->fixed/maybe body)])
           (if fixed fixed (complete transcript body))))
       (define msg* : FixedMessage (message (message-role msg) body*))
       (loop (cdr remaining)
             (append transcript (list msg*))
             (cons msg* acc))])))

(: body->fixed/maybe (-> Body (Option FixedBody)))
(define (body->fixed/maybe body)
  (let loop ([remaining : Body body]
             [acc : FixedBody '()])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define p (car remaining))
       (if (fixed-part? p)
           (loop (cdr remaining) (cons p acc))
           #f)])))
