#lang typed/racket/base

(require racket/string
         "../main.rkt")

(provide PromptRenderer
         plain-renderer
         make-chat-template-renderer)

(define-type PromptRenderer (-> EvaluatedProgram String String))

(: plain-renderer PromptRenderer)
(define (plain-renderer transcript prefix)
  (join-prompt (render-transcript transcript) prefix))

(: make-chat-template-renderer (-> String PromptRenderer))
(define (make-chat-template-renderer template)
  (lambda ([transcript : EvaluatedProgram] [prefix : String])
    (define rendered (render-transcript transcript))
    (define with-transcript
      (string-replace template "{{transcript}}" rendered))
    (string-replace with-transcript "{{prefix}}" prefix)))

(: join-prompt (-> String String String))
(define (join-prompt prompt prefix)
  (cond
    [(string=? prompt "") prefix]
    [(string=? prefix "") prompt]
    [else (string-append prompt "\n" prefix)]))

(: render-transcript (-> EvaluatedProgram String))
(define (render-transcript messages)
  (string-join
   (for/list : (Listof String) ([msg (in-list messages)])
     (format "~a: ~a"
             (symbol->string (message-role msg))
             (message->string msg)))
   "\n"))
