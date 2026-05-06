#lang typed/racket/base

(require racket/list
         racket/port
         racket/string
         typed/json
         typed/net/url
         "../main.rkt")

(provide make-llama-cpp-llm)

(define-type Generator (-> String String String))
(define-type Captures (Immutable-HashTable String String))
(define-type GenIds (HashTable gen String))
(define-type SelectIds (HashTable select String))

(struct compiled ([grammar : String] [rx : Regexp] [slots : (Listof String)] [gen-ids : GenIds] [select-ids : SelectIds]) #:transparent)
(struct fragment ([grammar : String] [rx : String] [slots : (Listof String)]) #:transparent)

(: make-llama-cpp-llm (->* () (#:server-url String #:generate (Option Generator)) LLM))
(define (make-llama-cpp-llm
         #:server-url [server-url (or (getenv "RACK_LLM_LLAMA_SERVER")
                                      "http://localhost:8080")]
         #:generate [generate #f])
  (define generate-text (or generate (make-http-generator server-url)))
  (lambda ([transcript : EvaluatedProgram] [target : (Listof expr)])
    (define c (compile-body target))
    (define prompt (messages->prompt transcript))
    (define text (generate-text prompt (compiled-grammar c)))
    (define captures (match-compiled c text))
    (reduce-body target
                 captures
                 (compiled-gen-ids c)
                 (compiled-select-ids c))))

(: make-http-generator (-> String Generator))
(define (make-http-generator server-url)
  (define endpoint
    (string->url (string-append (regexp-replace #rx"/+$" server-url "") "/completion")))
  (lambda ([prompt : String] [grammar : String])
    (define payload
      (string->bytes/utf-8
       (jsexpr->string
        (hash 'prompt prompt
              'grammar grammar))))
    (define in
      (post-pure-port endpoint
                      payload
                      (list "Content-Type: application/json")))
    (define response (port->string in))
    (close-input-port in)
    (response-content (string->jsexpr response))))

(: compile-body (-> (Listof expr) compiled))
(define (compile-body body)
  (define next-id : Natural 0)
  (define gen-ids : GenIds (make-hasheq))
  (define select-ids : SelectIds (make-hasheq))
  (define rules : (Listof String) '())

  (: fresh (-> String String))
  (define (fresh prefix)
    (set! next-id (add1 next-id))
    (format "~a_~a" prefix next-id))

  (: add-rule! (-> String Void))
  (define (add-rule! rule)
    (set! rules (cons rule rules)))

  (: emit-body (-> (Listof expr) fragment))
  (define (emit-body body)
    (define parts (map emit body))
    (fragment (string-join (map fragment-grammar parts) " ")
              (apply string-append (map fragment-rx parts))
              (append* (map fragment-slots parts))))

  (: emit (-> expr fragment))
  (define (emit expr)
    (cond
      [(lit? expr)
       (fragment (lark-string (lit-value expr))
                 (regexp-quote (lit-value expr))
                 '())]
      [(gen? expr)
       (define name (fresh "gen"))
       (define capture (capture-name "gen" name))
       (hash-set! gen-ids expr name)
       (add-rule!
        (format "~a[capture=~s, max_tokens=~a]: /(?s:.*)/"
                name capture (gen-max-tokens expr)))
       (fragment name "([\\s\\S]*?)" (list capture))]
      [(select? expr)
       (define name (fresh "sel"))
       (hash-set! select-ids expr name)
       (define variants (cons (select-first expr) (select-rest expr)))
       (define branches
         (for/list : (Listof fragment) ([variant (in-list variants)]
                                        [index : Natural (in-naturals)])
           (define branch-name (format "~a_~a" name index))
           (define branch (emit-body variant))
           (define capture (capture-name "select" name index))
           (add-rule!
            (format "~a[capture=~s]: ~a"
                    branch-name capture (fragment-grammar branch)))
           (fragment branch-name
                     (string-append "(" (fragment-rx branch) ")")
                     (cons capture (fragment-slots branch)))))
       (add-rule! (format "~a: ~a" name (string-join (map fragment-grammar branches) " | ")))
       (fragment name
                 (string-append "(?:" (string-join (map fragment-rx branches) "|") ")")
                 (append* (map fragment-slots branches)))]
      [(generated? expr)
       (fragment (lark-string (generated-text expr))
                 (regexp-quote (generated-text expr))
                 '())]
      [(selected? expr)
       (emit-body (selected-choice expr))]
      [else (error 'llama-cpp "unsupported expr: ~e" expr)]))

  (define start (emit-body body))
  (compiled
   (string-append
    "%llguidance {}\n\n"
    (format "start: ~a\n" (fragment-grammar start))
    (if (null? rules)
        ""
        (string-append "\n" (string-join (reverse rules) "\n") "\n")))
   (pregexp (string-append "^" (fragment-rx start) "$"))
   (fragment-slots start)
   (hash-copy gen-ids)
   (hash-copy select-ids)))

(: match-compiled (-> compiled String Captures))
(define (match-compiled c text)
  (define match (regexp-match (compiled-rx c) text))
  (unless (and match (equal? (car match) text))
    (error 'llama-cpp "generated text does not match grammar: ~s" text))
  (define captures (cdr match))
  (unless (= (length captures) (length (compiled-slots c)))
    (error 'llama-cpp "internal matcher slot mismatch"))
  (for/hash : Captures ([slot (in-list (compiled-slots c))]
                        [value (in-list captures)]
                        #:when (string? value))
    (values slot value)))

(: reduce-body (-> (Listof expr) Captures GenIds SelectIds (Listof value)))
(define (reduce-body body captures gen-ids select-ids)
  (map (lambda ([child : expr]) (reduce-expr child captures gen-ids select-ids))
       body))

(: reduce-expr (-> expr Captures GenIds SelectIds value))
(define (reduce-expr expr captures gen-ids select-ids)
  (cond
    [(lit? expr) expr]
    [(gen? expr)
     (define rule-name (hash-ref gen-ids expr))
     (define capture (capture-name "gen" rule-name))
     (generated expr
                (hash-ref captures
                          capture
                          (lambda ()
                            (error 'llama-cpp "missing string capture ~s in ~s" capture captures))))]
    [(select? expr)
     (define rule-name (hash-ref select-ids expr))
     (define variants (cons (select-first expr) (select-rest expr)))
     (define index (selected-index captures rule-name variants))
     (unless index
       (error 'llama-cpp "missing select capture for ~a" rule-name))
     (selected expr
               (reduce-body (list-ref variants index) captures gen-ids select-ids))]
    [(generated? expr) expr]
    [(selected? expr)
     (selected (selected-source expr)
               (reduce-body (selected-choice expr) captures gen-ids select-ids))]
    [else (error 'llama-cpp "unsupported expr: ~e" expr)]))

(: messages->prompt (-> EvaluatedProgram String))
(define (messages->prompt messages)
  (string-join
   (for/list : (Listof String) ([msg (in-list messages)])
     (format "~a: ~a"
             (symbol->string (message-role msg))
             (render-body (message-body msg))))
   "\n"))

(: render-body (-> (Listof value) String))
(define (render-body body)
  (apply string-append (map render-expr body)))

(: render-expr (-> value String))
(define (render-expr expr)
  (cond
    [(lit? expr) (lit-value expr)]
    [(generated? expr) (generated-text expr)]
    [(selected? expr) (render-body (selected-choice expr))]
    [else (error 'llama-cpp "unsupported fixed expr: ~e" expr)]))

(: selected-index (-> Captures String (Listof (Listof expr)) (Option Natural)))
(define (selected-index captures rule-name variants)
  (let loop ([rest : (Listof (Listof expr)) variants]
             [index : Natural 0])
    (cond
      [(null? rest) #f]
      [(hash-has-key? captures (capture-name "select" rule-name index)) index]
      [else (loop (cdr rest) (add1 index))])))

(: capture-name (case-> (-> String String String)
                       (-> String String Natural String)))
(define (capture-name kind rule-name [index #f])
  (if index
      (format "~a:~a:~a" kind rule-name index)
      (format "~a:~a" kind rule-name)))

(: response-content (-> JSExpr String))
(define (response-content js)
  (define content
    (if (hash? js)
        (hash-ref js 'content
                  (lambda ()
                    (hash-ref js "content" (lambda () #f))))
        #f))
  (unless (string? content)
    (error 'llama-cpp "server response has no string content: ~s" js))
  content)

(: lark-string (-> String String))
(define (lark-string s)
  (format "~s" s))
