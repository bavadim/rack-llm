#lang typed/racket/base

(require racket/list
         racket/port
         racket/string
         typed/json
         typed/net/url
         "../main.rkt")

(provide make-llama-cpp-llm)

(define-type TextGenerator (-> String String String))
(define-type CapturedValues (Immutable-HashTable String String))
(define-type GenerationRuleIds (HashTable gen String))
(define-type SelectionRuleIds (HashTable select String))

(struct grammar-compilation ([grammar : String] [regex : Regexp] [capture-slots : (Listof String)] [generation-rule-ids : GenerationRuleIds] [selection-rule-ids : SelectionRuleIds]) #:transparent)
(struct compilation-fragment ([grammar-rule : String] [regex-pattern : String] [capture-slots : (Listof String)]) #:transparent)

(: make-llama-cpp-llm (->* () (#:server-url String #:generate (Option TextGenerator)) LLM))
(define (make-llama-cpp-llm
         #:server-url [server-url (or (getenv "RACK_LLM_LLAMA_SERVER")
                                      "http://localhost:8080")]
         #:generate [generate #f])
  (define generate-text (or generate (make-http-generator server-url)))
  (lambda ([transcript : EvaluatedProgram] [target : (Listof expr)])
    (define compilation (compile-expressions target))
    (define prompt (messages->prompt transcript))
    (define text (generate-text prompt (grammar-compilation-grammar compilation)))
    (define captures (match-compilation compilation text))
    (reduce-expressions target
                        captures
                        (grammar-compilation-generation-rule-ids compilation)
                        (grammar-compilation-selection-rule-ids compilation))))

(: make-http-generator (-> String TextGenerator))
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
    (extract-response-content (string->jsexpr response))))

(: compile-expressions (-> (Listof expr) grammar-compilation))
(define (compile-expressions expressions)
  (define next-id : Natural 0)
  (define generation-rule-ids : GenerationRuleIds (make-hasheq))
  (define selection-rule-ids : SelectionRuleIds (make-hasheq))
  (define rules : (Listof String) '())

  (: generate-unique-id (-> String String))
  (define (generate-unique-id prefix)
    (set! next-id (add1 next-id))
    (format "~a_~a" prefix next-id))

  (: add-grammar-rule! (-> String Void))
  (define (add-grammar-rule! rule)
    (set! rules (cons rule rules)))

  (: compile-expression-list (-> (Listof expr) compilation-fragment))
  (define (compile-expression-list expr-list)
    (define fragments (map compile-single-expression expr-list))
    (compilation-fragment (string-join (map compilation-fragment-grammar-rule fragments) " ")
                          (apply string-append (map compilation-fragment-regex-pattern fragments))
                          (append* (map compilation-fragment-capture-slots fragments))))

  (: compile-single-expression (-> expr compilation-fragment))
  (define (compile-single-expression expr)
    (cond
      [(lit? expr)
       (compilation-fragment (quote-string (lit-value expr))
                             (regexp-quote (lit-value expr))
                             '())]
      [(gen? expr)
       (define rule-name (generate-unique-id "gen"))
       (define capture-key (make-capture-name "gen" rule-name))
       (hash-set! generation-rule-ids expr rule-name)
       (add-grammar-rule!
        (format "~a[capture=~s, max_tokens=~a]: /(?s:.*)/"
                rule-name capture-key (gen-max-tokens expr)))
       (compilation-fragment rule-name "([\\s\\S]*?)" (list capture-key))]
      [(select? expr)
       (define rule-name (generate-unique-id "sel"))
       (hash-set! selection-rule-ids expr rule-name)
       (define options (cons (select-first expr) (select-rest expr)))
       (define option-fragments
         (for/list : (Listof compilation-fragment) ([option (in-list options)]
                                                    [index : Natural (in-naturals)])
           (define option-rule-name (format "~a_~a" rule-name index))
           (define option-fragment (compile-expression-list option))
           (define capture-key (make-capture-name "select" rule-name index))
           (add-grammar-rule!
            (format "~a[capture=~s]: ~a"
                    option-rule-name capture-key (compilation-fragment-grammar-rule option-fragment)))
           (compilation-fragment option-rule-name
                                 (string-append "(" (compilation-fragment-regex-pattern option-fragment) ")")
                                 (cons capture-key (compilation-fragment-capture-slots option-fragment)))))
       (add-grammar-rule! (format "~a: ~a" rule-name (string-join (map compilation-fragment-grammar-rule option-fragments) " | ")))
       (compilation-fragment rule-name
                             (string-append "(?:" (string-join (map compilation-fragment-regex-pattern option-fragments) "|") ")")
                             (append* (map compilation-fragment-capture-slots option-fragments)))]
      [(generated? expr)
       (compilation-fragment (quote-string (generated-text expr))
                             (regexp-quote (generated-text expr))
                             '())]
      [(selected? expr)
       (compile-expression-list (selected-choice expr))]
      [else (error 'llama-cpp "unsupported expr: ~e" expr)]))

  (define start-fragment (compile-expression-list expressions))
  (grammar-compilation
   (string-append
    "%llguidance {}\n\n"
    (format "start: ~a\n" (compilation-fragment-grammar-rule start-fragment))
    (if (null? rules)
        ""
        (string-append "\n" (string-join (reverse rules) "\n") "\n")))
   (pregexp (string-append "^" (compilation-fragment-regex-pattern start-fragment) "$"))
   (compilation-fragment-capture-slots start-fragment)
   (hash-copy generation-rule-ids)
   (hash-copy selection-rule-ids)))

(: match-compilation (-> grammar-compilation String CapturedValues))
(define (match-compilation compilation text)
  (define match (regexp-match (grammar-compilation-regex compilation) text))
  (unless (and match (equal? (car match) text))
    (error 'llama-cpp "generated text does not match grammar: ~s" text))
  (define captures (cdr match))
  (unless (= (length captures) (length (grammar-compilation-capture-slots compilation)))
    (error 'llama-cpp "internal matcher slot mismatch"))
  (for/hash : CapturedValues ([slot (in-list (grammar-compilation-capture-slots compilation))]
                              [value (in-list captures)]
                              #:when (string? value))
    (values slot value)))

(: reduce-expressions (-> (Listof expr) CapturedValues GenerationRuleIds SelectionRuleIds (Listof value)))
(define (reduce-expressions expressions captures generation-rule-ids selection-rule-ids)
  (map (lambda ([child : expr]) (reduce-single-expression child captures generation-rule-ids selection-rule-ids))
       expressions))

(: reduce-single-expression (-> expr CapturedValues GenerationRuleIds SelectionRuleIds value))
(define (reduce-single-expression expr captures generation-rule-ids selection-rule-ids)
  (cond
    [(lit? expr) expr]
    [(gen? expr)
     (define rule-name (hash-ref generation-rule-ids expr))
     (define capture-key (make-capture-name "gen" rule-name))
     (generated expr
                (hash-ref captures
                          capture-key
                          (lambda ()
                            (error 'llama-cpp "missing string capture ~s in ~s" capture-key captures))))]
    [(select? expr)
     (define rule-name (hash-ref selection-rule-ids expr))
     (define options (cons (select-first expr) (select-rest expr)))
     (define selected-index (find-selected-index captures rule-name options))
     (unless selected-index
       (error 'llama-cpp "missing select capture for ~a" rule-name))
     (selected expr
               (reduce-expressions (list-ref options selected-index) captures generation-rule-ids selection-rule-ids))]
    [(generated? expr) expr]
    [(selected? expr)
     (selected (selected-source expr)
               (reduce-expressions (selected-choice expr) captures generation-rule-ids selection-rule-ids))]
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

(: find-selected-index (-> CapturedValues String (Listof (Listof expr)) (Option Natural)))
(define (find-selected-index captures rule-name options)
  (let loop ([remaining-options : (Listof (Listof expr)) options]
             [index : Natural 0])
    (cond
      [(null? remaining-options) #f]
      [(hash-has-key? captures (make-capture-name "select" rule-name index)) index]
      [else (loop (cdr remaining-options) (add1 index))])))

(: make-capture-name (case-> (-> String String String)
                              (-> String String Natural String)))
(define (make-capture-name kind rule-name [index #f])
  (if index
      (format "~a:~a:~a" kind rule-name index)
      (format "~a:~a" kind rule-name)))

(: extract-response-content (-> JSExpr String))
(define (extract-response-content js)
  (define content
    (if (hash? js)
        (hash-ref js 'content
                  (lambda ()
                    (hash-ref js "content" (lambda () #f))))
        #f))
  (unless (string? content)
    (error 'llama-cpp "server response has no string content: ~s" js))
  content)

(: quote-string (-> String String))
(define (quote-string s)
  (format "~s" s))
