#lang racket/base

(require racket/list
         racket/string
         "result.rkt")

(provide (struct-out chat-model)
         make-chat-model
         model-complete

         run
         chat
         message
         system
         user
         assistant

         ;; Internal state helpers intentionally exported for submodules.
         ;; They are not meant to be the pleasant public API. Such is life.
         (struct-out llm-state)
         state-add-message
         state-append-buffer
         state-set-buffer
         state-capture
         state-trace)

(struct chat-model
  (name       ; String/Symbol, for logs
   complete)  ; procedure: messages #:max-tokens ... -> string
  #:transparent)

(define (make-chat-model complete #:name [name "model"])
  (chat-model name complete))

(define (model-complete model messages
                        #:max-tokens [max-tokens #f]
                        #:temperature [temperature #f]
                        #:stop [stop #f]
                        #:extra [extra (hash)])
  ((chat-model-complete model)
   messages
   #:max-tokens max-tokens
   #:temperature temperature
   #:stop stop
   #:extra extra))

(struct llm-state
  (model messages buffer captures trace)
  #:transparent)

(define (state-add-message st role content)
  (struct-copy llm-state st
    [messages (append (llm-state-messages st)
                      (list (hash 'role role 'content (format "~a" content))))]
    [trace (append (llm-state-trace st)
                   (list (list 'message role content)))]))

(define (state-append-buffer st text)
  (define s (format "~a" text))
  (struct-copy llm-state st
    [buffer (string-append (llm-state-buffer st) s)]
    [trace (append (llm-state-trace st)
                   (list (list 'emit s)))]))

(define (state-set-buffer st text)
  (struct-copy llm-state st [buffer (format "~a" text)]))

(define (state-capture st key value)
  (if key
      (struct-copy llm-state st
        [captures (hash-set (llm-state-captures st) key value)]
        [trace (append (llm-state-trace st)
                       (list (list 'capture key value)))])
      st))

(define (state-trace st entry)
  (struct-copy llm-state st
    [trace (append (llm-state-trace st) (list entry))]))

(define (message role content)
  (lambda (st)
    (state-add-message st role content)))

(define (system content)
  (message "system" content))

(define (user content)
  (message "user" content))

(define (assistant grammar)
  (lambda (st)
    (define st0 (state-set-buffer st ""))
    (define st1 (grammar st0))
    (define text (llm-state-buffer st1))
    (define st2 (state-set-buffer st1 ""))
    (state-add-message st2 "assistant" text)))

(define (chat . parts)
  (lambda (st)
    (for/fold ([current st]) ([part (in-list parts)])
      (part current))))

(define (last-assistant-text messages)
  (for/fold ([last ""]) ([m (in-list messages)])
    (if (equal? (hash-ref m 'role "") "assistant")
        (hash-ref m 'content "")
        last)))

(define (run model program)
  (define initial
    (llm-state model '() "" (hash) '()))
  (define final-state (program initial))
  (result (llm-state-messages final-state)
          (llm-state-captures final-state)
          (last-assistant-text (llm-state-messages final-state))
          (llm-state-trace final-state)
          final-state))
