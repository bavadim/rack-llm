#lang typed/racket/base

(require "common-combinators.rkt")

(require/typed racket/list
  [range (-> Natural Natural (Listof Natural))]
  [remove-duplicates (All (A) (-> (Listof A) (Listof A)))]
  [split-at (All (A) (-> (Listof A) Natural (Values (Listof A) (Listof A))))])

(provide Role
         Grammar
         Choice
         Program
         EvaluatedProgram
         EvaluatedBody
         EvaluatedBodyStream
         EvaluatedProgramStream
         TokenBudget
         LogProb
         TokenOracle
         (struct-out expr)
         (struct-out value)
         (struct-out message)
         (struct-out lit)
         (struct-out gen)
         (struct-out select)
         (struct-out seq-expr)
         (struct-out choice-expr)
         (struct-out optional-expr)
         (struct-out repeat-expr)
         (struct-out sep-by-expr)
         (struct-out regex-expr)
         (struct-out capture-expr)
         (struct-out capture-value)
         (struct-out generated)
         (struct-out selected)
         (struct-out token-candidate)
         system
         user
         assistant
         evaluated-body?
         Matcher
         MatcherState
         compile-matcher
         matcher-start
         matcher-advance
         matcher-yields
         matcher-text
         matcher-viable?
         matcher-accepting?
         matcher-captures
         target-token-budget)

(define-type Role (U 'system 'user 'assistant))
(define-type Grammar (Listof expr))
(define-type Choice Grammar)
(define-type Program (Listof (message expr)))
(define-type EvaluatedProgram (Listof (message value)))
(define-type EvaluatedBody (Listof value))
(define-type EvaluatedBodyStream (Sequenceof EvaluatedBody))
(define-type EvaluatedProgramStream (Sequenceof EvaluatedProgram))
(define-type TokenPieces (Listof String))
(define-type TokenBoundaries (Listof Natural))
(define-type ParsePosition Natural)
(define-type TokenBudget Natural)
(define-type LogProb Flonum)

;; Public grammar DSL

;; A backend is only a token oracle. It sees the already fixed transcript and
;; the current generated prefix, and returns a finite top-K approximation of
;; q(token | transcript, prefix).
(struct token-candidate
  ([text : String]
   [logp : LogProb])
  #:transparent)

(define-type TokenOracle (-> EvaluatedProgram String (Listof token-candidate)))

(struct expr () #:transparent)
(struct value expr () #:transparent)

(struct: (A) message
  ([role : Role]
   [body : (Listof A)])
  #:transparent)

(struct lit value
  ([value : String])
  #:transparent)

(struct gen expr
  ([max-tokens : TokenBudget])
  #:transparent)

(struct select expr
  ([first : Choice]
   [rest : (Listof Choice)])
  #:transparent)

(struct seq-expr expr
  ([items : Grammar])
  #:transparent)

(struct choice-expr expr
  ([options : (Listof expr)])
  #:transparent)

(struct optional-expr expr
  ([item : expr])
  #:transparent)

(struct repeat-expr expr
  ([item : expr]
   [min : Natural]
   [max : Natural])
  #:transparent)

(struct sep-by-expr expr
  ([item : expr]
   [separator : expr]
   [min : Natural]
   [max : Natural])
  #:transparent)

(struct regex-expr expr
  ([pattern : String])
  #:transparent)

(struct capture-expr expr
  ([name : Symbol]
   [item : expr])
  #:transparent)

(struct generated value
  ([source : gen]
   [text : String])
  #:transparent)

(struct selected value
  ([source : select]
   [choice : EvaluatedBody])
  #:transparent)

(struct capture-value value
  ([name : Symbol]
   [text : String])
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

(define-predicate evaluated-body? EvaluatedBody)

;; Matcher

(struct parse-out
  ([body : EvaluatedBody]
   [captures : (HashTable Symbol String)])
  #:transparent)

(struct parse-result
  ([live? : Boolean]
   [outs : (Listof parse-out)])
  #:transparent)
(define-type ParseResult parse-result)

(struct parse-input
  ([text : String]
   [boundaries : TokenBoundaries]
   [end : ParsePosition])
  #:transparent)
(define-type ParseInput parse-input)

(define-type Parser (-> ParseInput ParsePosition ParseResult))

(struct matcher
  ([id : Symbol]
   [parser : Parser])
  #:transparent)
(define-type Matcher matcher)

(struct matcher-position
  ([matcher : Matcher]
   [pieces : TokenPieces]
   [result : ParseResult])
  #:transparent)

(struct matcher-state
  ([grammar-id : Symbol]
   [position : Any]
   [captures : (HashTable Symbol String)]
   [text : String]
   [viable? : Boolean]
   [accepting? : Boolean])
  #:transparent)
(define-type MatcherState matcher-state)

(define matcher-counter : Natural 0)

(: compile-matcher (-> (U Grammar expr) Matcher))
(define (compile-matcher target)
  (define grammar (target->grammar target))
  (set! matcher-counter (add1 matcher-counter))
  (matcher (string->symbol (format "grammar~a" matcher-counter))
           (parse-seq grammar final-parser #f)))

(: matcher-start (-> Matcher MatcherState))
(define (matcher-start m)
  (make-matcher-state m '() "" (replay-matcher-run m '())))

(: matcher-advance
   (case->
    (-> MatcherState String MatcherState)
    (-> Matcher MatcherState String MatcherState)))
(define matcher-advance
  (case-lambda
    [([state : MatcherState] [piece : String])
     (define pos (matcher-position-from-state state))
     (advance-with-matcher (matcher-position-matcher pos) state piece)]
    [([m : Matcher] [state : MatcherState] [piece : String])
     (advance-with-matcher m state piece)]))

(: matcher-yields (-> MatcherState (Listof EvaluatedBody)))
(define (matcher-yields state)
  (map parse-out-body
       (parse-result-outs
        (matcher-position-result (matcher-position-from-state state)))))

(: matcher-text (-> MatcherState String))
(define (matcher-text state)
  (matcher-state-text state))

(: matcher-viable? (-> MatcherState Boolean))
(define (matcher-viable? state)
  (matcher-state-viable? state))

(: matcher-accepting? (-> MatcherState Boolean))
(define (matcher-accepting? state)
  (matcher-state-accepting? state))

(: matcher-captures (-> MatcherState (HashTable Symbol String)))
(define (matcher-captures state)
  (matcher-state-captures state))

(: target->grammar (-> (U Grammar expr) Grammar))
(define (target->grammar target)
  (if (list? target) target (list target)))

(: make-matcher-state (-> Matcher TokenPieces String ParseResult MatcherState))
(define (make-matcher-state m pieces text result)
  (matcher-state
   (matcher-id m)
   (matcher-position m pieces result)
   (first-captures result)
   text
   (result-viable? result)
   (not (null? (parse-result-outs result)))))

(: matcher-position-from-state (-> MatcherState matcher-position))
(define (matcher-position-from-state state)
  (assert (matcher-state-position state) matcher-position?))

(: advance-with-matcher (-> Matcher MatcherState String MatcherState))
(define (advance-with-matcher m state piece)
  (define pos (matcher-position-from-state state))
  (define pieces (append (matcher-position-pieces pos) (list piece)))
  (define text (string-append (matcher-state-text state) piece))
  (make-matcher-state m pieces text (replay-matcher-run m pieces)))

(: replay-matcher-run (-> Matcher TokenPieces ParseResult))
(define (replay-matcher-run m pieces)
  (define text (apply string-append pieces))
  (define boundaries (token-boundaries pieces))
  (result-dedupe ((matcher-parser m) (parse-input text boundaries (string-length text)) 0)))

;; Parser combinators

(: final-parser Parser)
(define (final-parser source pos)
  (if (= pos (parse-input-end source)) (result-done '()) result-empty))

(: parse-seq (-> Grammar Parser Boolean Parser))
(define (parse-seq exprs k k-follows?)
  (cond
    [(null? exprs) k]
    [else
     (define rest (cdr exprs))
     (define next (parse-seq rest k k-follows?))
     (define follows? (or (not (null? rest)) k-follows?))
     (lambda ([source : ParseInput] [pos : ParsePosition])
       (if (> pos (parse-input-end source))
           result-empty
           (parse-expr (car exprs) next follows? source pos)))]))

(: parse-expr (-> expr Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-expr e k follows? source pos)
  (cond
    [(lit? e)
     (parse-literal (lit-value e) e k source pos)]
    [(generated? e)
     (parse-literal (generated-text e) e k source pos)]
    [(selected? e)
     (parse-choice (selected-source e) (selected-choice e) k follows? source pos)]
    [(select? e)
     (result-choose
      (select-choices e)
      (lambda ([choice : Choice])
        (parse-choice e choice k follows? source pos)))]
    [(seq-expr? e)
     ((parse-seq (seq-expr-items e) k follows?) source pos)]
    [(choice-expr? e)
     (result-choose
      (choice-expr-options e)
      (lambda ([option : expr])
        (parse-expr option k follows? source pos)))]
    [(optional-expr? e)
     (result-union (k source pos)
                   (parse-expr (optional-expr-item e) k follows? source pos))]
    [(repeat-expr? e)
     (parse-repeat (repeat-expr-item e)
                   (repeat-expr-min e)
                   (repeat-expr-max e)
                   k
                   follows?
                   source
                   pos)]
    [(sep-by-expr? e)
     (parse-sep-by (sep-by-expr-item e)
                   (sep-by-expr-separator e)
                   (sep-by-expr-min e)
                   (sep-by-expr-max e)
                   k
                   follows?
                   source
                   pos)]
    [(regex-expr? e)
     (parse-regex (regex-expr-pattern e) k source pos)]
    [(capture-expr? e)
     (parse-capture (capture-expr-name e)
                    (capture-expr-item e)
                    k
                    follows?
                    source
                    pos)]
    [(gen? e)
     (parse-gen e k follows? source pos)]
    [else result-empty]))

(: parse-choice (-> select Choice Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-choice source choice k follows? input pos)
  (wrap-choice source
               (length choice)
               ((parse-seq choice k follows?) input pos)))

(: parse-literal (-> String value Parser ParseInput ParsePosition ParseResult))
(define (parse-literal literal value k source pos)
  (define available (substring (parse-input-text source) pos))
  (cond
    [(and (< (string-length available) (string-length literal))
          (prefix? literal available))
     result-live]
    [(prefix? available literal)
     (prepend-value value
                    (k source (+ pos (string-length literal))))]
    [else result-empty]))

(: prefix? (-> String String Boolean))
(define (prefix? s prefix)
  (and (<= (string-length prefix) (string-length s))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(: parse-gen (-> gen Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-gen expr k follows? source pos)
  (define boundaries (parse-input-boundaries source))
  (define token-index (position->token-index boundaries pos))
  (define max-take : Natural
    (min (gen-max-tokens expr)
         (remaining-token-count boundaries token-index)))
  (define closed
    (result-choose
     (filter (lambda ([n : Natural])
               (or (positive? n) follows?))
             (range 0 (add1 max-take)))
     (lambda ([n : Natural])
       (define end-pos (token-end-position boundaries pos token-index n))
       (define generated-text (substring (parse-input-text source) pos end-pos))
       (prepend-value (generated expr generated-text)
                      (k source end-pos)))))
  (if (< max-take (gen-max-tokens expr))
      (result-union result-live closed)
      closed))

(: parse-repeat (-> expr Natural Natural Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-repeat item min-count max-count k follows? source pos)
  (let loop ([count : Natural 0]
             [current-pos : ParsePosition pos])
    (define closed
      (if (>= count min-count)
          (k source current-pos)
          result-empty))
    (cond
      [(>= count max-count) closed]
      [else
       (result-union
        closed
        (parse-expr
         item
         (lambda ([next-source : ParseInput] [next-pos : ParsePosition])
           (if (= next-pos current-pos)
               result-empty
               (loop (add1 count) next-pos)))
         follows?
         source
         current-pos))])))

(: parse-sep-by (-> expr expr Natural Natural Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-sep-by item separator min-count max-count k follows? source pos)
  (let loop ([count : Natural 0]
             [current-pos : ParsePosition pos])
    (define closed
      (if (>= count min-count)
          (k source current-pos)
          result-empty))
    (cond
      [(>= count max-count) closed]
      [(zero? count)
       (result-union
        closed
        (parse-expr
         item
         (lambda ([next-source : ParseInput] [next-pos : ParsePosition])
           (if (= next-pos current-pos)
               result-empty
               (loop (add1 count) next-pos)))
         follows?
         source
         current-pos))]
      [else
       (result-union
        closed
        (parse-expr
         separator
         (lambda ([next-source : ParseInput] [sep-pos : ParsePosition])
           (parse-expr
            item
            (lambda ([item-source : ParseInput] [item-pos : ParsePosition])
              (if (= item-pos sep-pos)
                  result-empty
                  (loop (add1 count) item-pos)))
            follows?
            next-source
            sep-pos))
         follows?
         source
         current-pos))])))

(: parse-regex (-> String Parser ParseInput ParsePosition ParseResult))
(define (parse-regex pattern k source pos)
  (define text (parse-input-text source))
  (define end (parse-input-end source))
  (define closed
    (for/fold ([acc : ParseResult result-empty])
              ([next-pos (in-range pos (add1 end))])
      (define next-position (assert next-pos exact-nonnegative-integer?))
      (define piece (substring text pos next-position))
      (if (regex-full-match? pattern piece)
          (result-union acc (k source next-position))
          acc)))
  (define available (substring text pos end))
  (if (regex-prefix-possible? pattern available)
      (result-union result-live closed)
      closed))

(: parse-capture (-> Symbol expr Parser Boolean ParseInput ParsePosition ParseResult))
(define (parse-capture name item k follows? source pos)
  (parse-expr
   item
   (lambda ([next-source : ParseInput] [next-pos : ParsePosition])
     (result-add-capture
      name
      (substring (parse-input-text source) pos next-pos)
      (k next-source next-pos)))
   follows?
   source
   pos))

;; Parse result algebra

(define result-empty (parse-result #f '()))
(define result-live (parse-result #t '()))

(: result-done (-> EvaluatedBody ParseResult))
(define (result-done body)
  (parse-result #f (list (parse-out body (ann (hash) (HashTable Symbol String))))))

(: result-dedupe (-> ParseResult ParseResult))
(define (result-dedupe m)
  (parse-result (parse-result-live? m)
                (remove-duplicates (parse-result-outs m))))

(: result-union (-> ParseResult ParseResult ParseResult))
(define (result-union left right)
  (parse-result (or (parse-result-live? left) (parse-result-live? right))
                (append (parse-result-outs left) (parse-result-outs right))))

(: result-choose (All (A) (-> (Listof A) (-> A ParseResult) ParseResult)))
(define (result-choose xs f)
  (foldr (lambda ([x : A] [acc : ParseResult])
           (result-union (f x) acc))
         result-empty
         xs))

(: result-map (-> (-> EvaluatedBody EvaluatedBody) ParseResult ParseResult))
(define (result-map f m)
  (parse-result (parse-result-live? m)
                (map (lambda ([out : parse-out])
                       (parse-out (f (parse-out-body out))
                                  (parse-out-captures out)))
                     (parse-result-outs m))))

(: result-add-capture (-> Symbol String ParseResult ParseResult))
(define (result-add-capture name text m)
  (parse-result
   (parse-result-live? m)
   (map (lambda ([out : parse-out])
          (parse-out (parse-out-body out)
                     (hash-set (parse-out-captures out) name text)))
        (parse-result-outs m))))

(: result-viable? (-> ParseResult Boolean))
(define (result-viable? result)
  (or (parse-result-live? result)
      (not (null? (parse-result-outs result)))))

(: first-captures (-> ParseResult (HashTable Symbol String)))
(define (first-captures result)
  (cond
    [(null? (parse-result-outs result)) (ann (hash) (HashTable Symbol String))]
    [else (parse-out-captures (car (parse-result-outs result)))]))

(: prepend-value (-> value ParseResult ParseResult))
(define (prepend-value value results)
  (result-map (lambda ([values : EvaluatedBody])
                (cons value values))
              results))

(: wrap-choice (-> select Natural ParseResult ParseResult))
(define (wrap-choice source choice-size results)
  (result-map
   (lambda ([values : EvaluatedBody])
     (let-values ([(choice tail) (split-at values choice-size)])
       (cons (selected source choice) tail)))
   results))

;; Token geometry

(: token-boundaries (-> TokenPieces TokenBoundaries))
(define (token-boundaries pieces)
  (let loop ([remaining : (Listof String) pieces]
             [pos : Natural 0]
             [acc : (Listof Natural) '(0)])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define next-pos (+ pos (string-length (car remaining))))
       (loop (cdr remaining) next-pos (cons next-pos acc))])))

(: position->token-index (-> TokenBoundaries ParsePosition Natural))
(define (position->token-index boundaries pos)
  (let loop ([xs : (Listof Natural) boundaries]
             [i : Natural 0])
    (cond
      [(or (null? (cdr xs)) (= (car xs) pos)) i]
      [(< pos (cadr xs)) i]
      [else (loop (cdr xs) (add1 i))])))

(: token-count (-> TokenBoundaries Natural))
(define (token-count boundaries)
  (assert (sub1 (length boundaries)) exact-nonnegative-integer?))

(: remaining-token-count (-> TokenBoundaries Natural Natural))
(define (remaining-token-count boundaries token-index)
  (assert (- (token-count boundaries) token-index) exact-nonnegative-integer?))

(: token-end-position (-> TokenBoundaries ParsePosition Natural Natural ParsePosition))
(define (token-end-position boundaries pos token-index n)
  (if (zero? n)
      pos
      (list-ref boundaries (+ token-index n))))

;; Grammar metadata

(: target-token-budget (-> Grammar Natural))
(define (target-token-budget exprs)
  (sum-map expr-token-budget exprs))

(: expr-token-budget (-> expr Natural))
(define (expr-token-budget e)
  (cond
    [(gen? e) (gen-max-tokens e)]
    [(select? e) (apply max (map target-token-budget (select-choices e)))]
    [(selected? e) (target-token-budget (selected-choice e))]
    [(seq-expr? e) (target-token-budget (seq-expr-items e))]
    [(choice-expr? e)
     (if (null? (choice-expr-options e))
         0
         (apply max (map expr-token-budget (choice-expr-options e))))]
    [(optional-expr? e) (expr-token-budget (optional-expr-item e))]
    [(repeat-expr? e) (* (repeat-expr-max e) (expr-token-budget (repeat-expr-item e)))]
    [(sep-by-expr? e)
     (+ (* (sep-by-expr-max e) (expr-token-budget (sep-by-expr-item e)))
        (if (zero? (sep-by-expr-max e))
            0
            (* (sub1 (sep-by-expr-max e))
               (expr-token-budget (sep-by-expr-separator e)))))]
    [(capture-expr? e) (expr-token-budget (capture-expr-item e))]
    [else 1]))

(: select-choices (-> select (Listof Choice)))
(define (select-choices e)
  (cons (select-first e) (select-rest e)))

;; Regex support is intentionally conservative. Full acceptance is exact for
;; Racket regexps; prefix viability handles the common regular fragments used
;; by the built-in JSON helpers and benchmark grammars.

(: regex-full-match? (-> String String Boolean))
(define (regex-full-match? pattern text)
  (regexp-match? (pregexp (string-append "^(?:" pattern ")$")) text))

(: regex-prefix-possible? (-> String String Boolean))
(define (regex-prefix-possible? pattern text)
  (cond
    [(string=? text "") #t]
    [(string=? pattern "[0-9]") (and (<= (string-length text) 1)
                                     (all-chars-match? char-numeric? text))]
    [(string=? pattern "[0-9]+") (all-chars-match? char-numeric? text)]
    [(string=? pattern "[a-z]+") (all-chars-match? lower-alpha? text)]
    [(string=? pattern "[A-Za-z]+") (all-chars-match? ascii-alpha? text)]
    [(string=? pattern "[A-Za-z0-9_ -]*") (all-chars-match? json-simple-char? text)]
    [else (or (regex-full-match? pattern text)
              (not (regexp-match? #px"[\r\n]" text)))]))

(: all-chars-match? (-> (-> Char Boolean) String Boolean))
(define (all-chars-match? pred text)
  (for/and : Boolean ([ch (in-string text)])
    (pred ch)))

(: lower-alpha? (-> Char Boolean))
(define (lower-alpha? ch)
  (and (char>=? ch #\a) (char<=? ch #\z)))

(: ascii-alpha? (-> Char Boolean))
(define (ascii-alpha? ch)
  (or (and (char>=? ch #\a) (char<=? ch #\z))
      (and (char>=? ch #\A) (char<=? ch #\Z))))

(: json-simple-char? (-> Char Boolean))
(define (json-simple-char? ch)
  (or (ascii-alpha? ch)
      (char-numeric? ch)
      (char=? ch #\_)
      (char=? ch #\space)
      (char=? ch #\-)))
