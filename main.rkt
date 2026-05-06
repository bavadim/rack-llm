#lang typed/racket/base

(provide (struct-out part)
         (struct-out fixed-part)
         (struct-out message)
         (struct-out lit)
         (struct-out gen)
         (struct-out select)
         (struct-out generated)
         (struct-out selected)
         Chat
         FixedChat
         Completer
         system
         user
         assistant
         (rename-out [eval-chat eval]))

(define-type Chat (Listof (message part)))
(define-type FixedChat (Listof (message fixed-part)))
(define-type Completer (-> FixedChat (Listof part) (Listof fixed-part)))

(struct part () #:transparent)
(struct fixed-part part () #:transparent)

(struct: (A) message
  ([role : (U 'system 'user 'assistant)]
   [body : (Listof A)])
  #:transparent)

(struct lit fixed-part
  ([value : String])
  #:transparent)

(struct gen part
  ([max-tokens : Natural])
  #:transparent)

(struct select part
  ([first : (Listof part)]
   [rest : (Listof (Listof part))])
  #:transparent)

(struct generated fixed-part
  ([source : gen]
   [text : String])
  #:transparent)

(struct selected fixed-part
  ([source : select]
   [choice : (Listof fixed-part)])
  #:transparent)

(: system (part * -> (message part)))
(define (system . parts)
  (message 'system parts))

(: user (part * -> (message part)))
(define (user . parts)
  (message 'user parts))

(: assistant (part * -> (message part)))
(define (assistant . parts)
  (message 'assistant parts))

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
       (define msg* : (message fixed-part) (message (message-role msg) body*))
       (loop (cdr remaining)
             (append transcript (list msg*))
             (cons msg* acc))])))

(: body->fixed/maybe (-> (Listof part) (Option (Listof fixed-part))))
(define (body->fixed/maybe body)
  (let loop ([remaining : (Listof part) body]
             [acc : (Listof fixed-part) '()])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define p (car remaining))
       (if (fixed-part? p)
           (loop (cdr remaining) (cons p acc))
           #f)])))
