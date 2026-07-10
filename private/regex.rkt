#lang typed/racket/base

(provide RegexProgram
         RegexMachine
         RegexState
         parse-regex-program
         instantiate-regex-machine
         regex-initial
         regex-step
         regex-token-valid?
         regex-accepting?
         regex-terminal?
         regex-allowed-ids)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))

(struct r-empty () #:transparent)
(struct r-eps () #:transparent)
(struct r-class ([ranges : (Listof (Pairof Char Char))]
                 [negated? : Boolean])
  #:transparent)
(struct r-alt ([left : RegexAst] [right : RegexAst]) #:transparent)
(struct r-cat ([left : RegexAst] [right : RegexAst]) #:transparent)
(struct r-star ([body : RegexAst]) #:transparent)
(struct r-repeat ([body : RegexAst]
                  [min-count : Natural]
                  [max-count : (Option Natural)])
  #:transparent)

(define-type RegexAst (U r-empty r-eps r-class r-alt r-cat r-star r-repeat))
(define-type NfaState Natural)

(struct template-literal ([text : String]) #:transparent)
(struct template-span ([class : r-class]
                       [min-count : Natural]
                       [max-count : Natural])
  #:transparent)
(define-type TemplatePiece (U template-literal template-span))

(struct template-pos ([piece-index : Natural] [offset : Natural]) #:transparent)
(struct template-state ([positions : (Listof template-pos)]) #:transparent)
(define-type RegexState (U NfaState template-state))

(struct raw-edge ([from : Natural] [label : (Option r-class)] [to : Natural]) #:transparent)
(struct nfa-edge ([label : (Option r-class)] [to : Natural]) #:transparent)
(struct nfa
  ([start : Natural]
   [accept : Natural]
   [adj : (Vectorof (Listof nfa-edge))]
   [epsilon-closures : (Vectorof (Option NfaState))]
   [accept-mask : NfaState]
   [consuming-state-mask : NfaState])
  #:transparent)
(struct fragment
  ([start : Natural]
   [accept : Natural]
   [edges : (Listof raw-edge)]
   [next-id : Natural])
  #:transparent)

(struct nfa-program
  ([source : String]
   [graph : nfa])
  #:transparent)
(struct template-program
  ([source : String]
   [pieces : (Vectorof TemplatePiece)])
  #:transparent)
(define-type RegexProgram (U nfa-program template-program))

(struct regex-machine
  ([program : RegexProgram]
   [token-texts : (Vectorof String)]
   [transition-cache : (Mutable-HashTable (Pairof RegexState TokenId) (Option RegexState))]
   [token-text-cache : (Mutable-HashTable (Pairof RegexState String) (Option RegexState))]
   [char-cache : (Mutable-HashTable (Pairof NfaState Char) NfaState)]
   [allowed-cache : (Mutable-HashTable RegexState TokenIds)]
   [first-char-index : (Mutable-HashTable Char TokenIds)]
   [empty-token-ids : TokenIds])
  #:transparent)
(define-type RegexMachine regex-machine)

(: parse-regex-program (-> String RegexProgram))
(define (parse-regex-program source)
  (define ast (parse-regex source))
  (define maybe-template (ast->template-pieces ast))
  (if maybe-template
      (template-program source (list->vector maybe-template))
      (nfa-program source (ast->nfa ast))))

(: instantiate-regex-machine (-> RegexProgram (Vectorof String) RegexMachine))
(define (instantiate-regex-machine program token-texts)
  (define-values (first-char-index empty-token-ids)
    (build-first-char-index token-texts))
  (regex-machine program
                 token-texts
                 (ann (make-hash) (Mutable-HashTable (Pairof RegexState TokenId) (Option RegexState)))
                 (ann (make-hash) (Mutable-HashTable (Pairof RegexState String) (Option RegexState)))
                 (ann (make-hash) (Mutable-HashTable (Pairof NfaState Char) NfaState))
                 (ann (make-hash) (Mutable-HashTable RegexState TokenIds))
                 first-char-index
                 empty-token-ids))

(: regex-initial (-> RegexMachine RegexState))
(define (regex-initial machine)
  (define program (regex-machine-program machine))
  (cond
    [(nfa-program? program)
     (closure-for-state (nfa-program-graph program)
                        (nfa-start (nfa-program-graph program)))]
    [(template-program? program)
     (template-initial (template-program-pieces program))]))

(: regex-step (-> RegexMachine RegexState TokenId (Option RegexState)))
(define (regex-step machine state id)
  (define key (cons state id))
  (define cache (regex-machine-transition-cache machine))
  (cond
    [(hash-has-key? cache key) (hash-ref cache key)]
    [else
     (define token (vector-ref (regex-machine-token-texts machine) id))
     (define result (regex-step/token-text machine state token))
     (hash-set! cache key result)
     result]))

(: regex-token-valid? (-> RegexMachine RegexState TokenId Boolean))
(define (regex-token-valid? machine state id)
  (and (regex-step/token-text machine
                              state
                              (vector-ref (regex-machine-token-texts machine) id))
       #t))

(: regex-step/token-text (-> RegexMachine RegexState String (Option RegexState)))
(define (regex-step/token-text machine state token)
  (define key (cons state token))
  (define cache (regex-machine-token-text-cache machine))
  (cond
    [(hash-has-key? cache key) (hash-ref cache key)]
    [else
     (define program (regex-machine-program machine))
     (define result
       (cond
         [(nfa-program? program)
          (define nfa-state (assert state exact-nonnegative-integer?))
          (define graph (nfa-program-graph program))
          (define next
            (for/fold ([current : NfaState nfa-state])
                      ([ch (in-string token)])
              (if (zero? current)
                  0
                  (move-char machine graph current ch))))
          (if (zero? next) #f next)]
         [(template-program? program)
          (define template-st (assert state template-state?))
          (template-step/token-text (template-program-pieces program) template-st token)]))
     (hash-set! cache key result)
     result]))

(: regex-accepting? (-> RegexMachine RegexState Boolean))
(define (regex-accepting? machine state)
  (define program (regex-machine-program machine))
  (cond
    [(nfa-program? program)
     (define nfa-state (assert state exact-nonnegative-integer?))
     (define graph (nfa-program-graph program))
     (not (zero? (bitwise-and nfa-state (nfa-accept-mask graph))))]
    [(template-program? program)
     (template-accepting? (template-program-pieces program)
                          (assert state template-state?))]))

(: regex-terminal? (-> RegexMachine RegexState Boolean))
(define (regex-terminal? machine state)
  (define program (regex-machine-program machine))
  (cond
    [(nfa-program? program)
     (define nfa-state (assert state exact-nonnegative-integer?))
     (define graph (nfa-program-graph program))
     (and (regex-accepting? machine state)
          (or (zero? (bitwise-and nfa-state (nfa-consuming-state-mask graph)))
              (not (has-nonempty-allowed-token? machine state))))]
    [(template-program? program)
     (and (regex-accepting? machine state)
          (not (has-nonempty-allowed-token? machine state)))]))

(: has-nonempty-allowed-token? (-> RegexMachine RegexState Boolean))
(define (has-nonempty-allowed-token? machine state)
  (define token-texts (regex-machine-token-texts machine))
  (for/or : Boolean ([id (in-list (regex-allowed-ids machine state))])
    (positive? (string-length (vector-ref token-texts id)))))

(: regex-allowed-ids (-> RegexMachine RegexState TokenIds))
(define (regex-allowed-ids machine state)
  (define cache (regex-machine-allowed-cache machine))
  (cond
    [(hash-has-key? cache state) (hash-ref cache state)]
    [else
     (define vocab (regex-machine-token-texts machine))
     (define allowed
       (cond
         [(and (template-program? (regex-machine-program machine))
               (template-state? state))
          (define maybe-ids
            (template-indexed-allowed-ids machine
                                          (template-program-pieces
                                           (assert (regex-machine-program machine) template-program?))
                                          state))
          (if maybe-ids
              maybe-ids
              (scan-regex-allowed-ids machine state vocab))]
         [else (scan-regex-allowed-ids machine state vocab)]))
     (hash-set! cache state allowed)
     allowed]))

(: scan-regex-allowed-ids (-> RegexMachine RegexState (Vectorof String) TokenIds))
(define (scan-regex-allowed-ids machine state vocab)
  (for/list : TokenIds
            ([id : Natural (in-range (vector-length vocab))]
             #:when (regex-step machine state id))
    id))

(: build-first-char-index (-> (Vectorof String)
                              (Values (Mutable-HashTable Char TokenIds) TokenIds)))
(define (build-first-char-index token-texts)
  (define index : (Mutable-HashTable Char TokenIds) (make-hash))
  (define empty-ids-rev
    (for/fold ([empty-ids : TokenIds '()])
              ([id : Natural (in-range (vector-length token-texts))])
      (define text (vector-ref token-texts id))
      (cond
        [(zero? (string-length text)) (cons id empty-ids)]
        [else
         (define ch (string-ref text 0))
         (hash-set! index ch (cons id (hash-ref index ch (lambda () (ann '() TokenIds)))))
         empty-ids])))
  (for ([ch (in-list (hash-keys index))])
    (hash-set! index ch (reverse (hash-ref index ch))))
  (values index (reverse empty-ids-rev)))

(: ast->template-pieces (-> RegexAst (Option (Listof TemplatePiece))))
(define (ast->template-pieces ast)
  (define atoms (flatten-concat ast))
  (let loop ([remaining : (Listof RegexAst) atoms]
             [literal-chars : (Listof Char) '()]
             [pieces : (Listof TemplatePiece) '()]
             [has-span? : Boolean #f])
    (cond
      [(null? remaining)
       (define final-pieces (flush-template-literal literal-chars pieces))
       (and has-span? (reverse final-pieces))]
      [else
       (define atom (car remaining))
       (define maybe-char (literal-ast-char atom))
       (cond
         [maybe-char
          (loop (cdr remaining)
                (cons maybe-char literal-chars)
                pieces
                has-span?)]
         [(r-eps? atom)
          (loop (cdr remaining) literal-chars pieces has-span?)]
         [else
          (define maybe-span (repeat-ast-span atom))
          (if maybe-span
              (loop (cdr remaining)
                    '()
                    (cons maybe-span (flush-template-literal literal-chars pieces))
                    #t)
              #f)])])))

(: flatten-concat (-> RegexAst (Listof RegexAst)))
(define (flatten-concat ast)
  (cond
    [(r-cat? ast)
     (append (flatten-concat (r-cat-left ast))
             (flatten-concat (r-cat-right ast)))]
    [else (list ast)]))

(: flush-template-literal (-> (Listof Char) (Listof TemplatePiece) (Listof TemplatePiece)))
(define (flush-template-literal literal-chars pieces)
  (if (null? literal-chars)
      pieces
      (cons (template-literal (list->string (reverse literal-chars))) pieces)))

(: literal-ast-char (-> RegexAst (Option Char)))
(define (literal-ast-char ast)
  (and (r-class? ast)
       (not (r-class-negated? ast))
       (let ([ranges (r-class-ranges ast)])
         (and (pair? ranges)
              (null? (cdr ranges))
              (let ([range (car ranges)])
                (and (char=? (car range) (cdr range))
                     (car range)))))))

(: repeat-ast-span (-> RegexAst (Option template-span)))
(define (repeat-ast-span ast)
  (and (r-repeat? ast)
       (r-repeat-max-count ast)
       (r-class? (r-repeat-body ast))
       (template-span (r-repeat-body ast)
                      (r-repeat-min-count ast)
                      (assert (r-repeat-max-count ast) exact-nonnegative-integer?))))

(: template-initial (-> (Vectorof TemplatePiece) template-state))
(define (template-initial pieces)
  (normalize-template-state pieces (list (template-pos 0 0))))

(: template-step/token-text (-> (Vectorof TemplatePiece) template-state String (Option template-state)))
(define (template-step/token-text pieces state token)
  (let loop ([current : (Option template-state) state]
             [index : Natural 0])
    (cond
      [(not current) #f]
      [(= index (string-length token)) current]
      [else
       (loop (template-step-char pieces current (string-ref token index))
             (assert (add1 index) exact-nonnegative-integer?))])))

(: template-step-char (-> (Vectorof TemplatePiece) template-state Char (Option template-state)))
(define (template-step-char pieces state ch)
  (define next-positions
    (for/fold ([acc : (Listof template-pos) '()])
              ([pos (in-list (template-state-positions state))])
      (append (template-consume-pos pieces pos ch) acc)))
  (and (pair? next-positions)
       (normalize-template-state pieces next-positions)))

(: template-consume-pos (-> (Vectorof TemplatePiece) template-pos Char (Listof template-pos)))
(define (template-consume-pos pieces pos ch)
  (define piece-count (vector-length pieces))
  (define index (template-pos-piece-index pos))
  (cond
    [(>= index piece-count) '()]
    [else
     (define piece (vector-ref pieces index))
     (cond
       [(template-literal? piece)
        (define text (template-literal-text piece))
        (define offset (template-pos-offset pos))
        (if (and (< offset (string-length text))
                 (char=? ch (string-ref text offset)))
            (list (if (= (add1 offset) (string-length text))
                      (template-pos (add1 index) 0)
                      (template-pos index (add1 offset))))
            '())]
       [(template-span? piece)
        (define offset (template-pos-offset pos))
        (if (and (< offset (template-span-max-count piece))
                 (class-contains? (template-span-class piece) ch))
            (list (template-pos index (add1 offset)))
            '())])]))

(: normalize-template-state (-> (Vectorof TemplatePiece) (Listof template-pos) template-state))
(define (normalize-template-state pieces positions)
  (template-state (normalize-template-positions pieces positions '())))

(: normalize-template-positions
   (-> (Vectorof TemplatePiece) (Listof template-pos) (Listof template-pos) (Listof template-pos)))
(define (normalize-template-positions pieces pending seen)
  (cond
    [(null? pending) (reverse seen)]
    [else
     (define pos (car pending))
     (define rest (cdr pending))
     (if (template-pos-member? pos seen)
         (normalize-template-positions pieces rest seen)
         (normalize-template-positions pieces
                                       (append (template-epsilon-targets pieces pos) rest)
                                       (cons pos seen)))]))

(: template-epsilon-targets (-> (Vectorof TemplatePiece) template-pos (Listof template-pos)))
(define (template-epsilon-targets pieces pos)
  (define piece-count (vector-length pieces))
  (define index (template-pos-piece-index pos))
  (cond
    [(>= index piece-count) '()]
    [else
     (define piece (vector-ref pieces index))
     (cond
       [(template-literal? piece)
        (if (= (string-length (template-literal-text piece)) (template-pos-offset pos))
            (list (template-pos (add1 index) 0))
            '())]
       [(template-span? piece)
        (if (>= (template-pos-offset pos) (template-span-min-count piece))
            (list (template-pos (add1 index) 0))
            '())])]))

(: template-pos-member? (-> template-pos (Listof template-pos) Boolean))
(define (template-pos-member? pos positions)
  (for/or : Boolean ([candidate (in-list positions)])
    (and (= (template-pos-piece-index pos) (template-pos-piece-index candidate))
         (= (template-pos-offset pos) (template-pos-offset candidate)))))

(: template-accepting? (-> (Vectorof TemplatePiece) template-state Boolean))
(define (template-accepting? pieces state)
  (define piece-count (vector-length pieces))
  (for/or : Boolean ([pos (in-list (template-state-positions state))])
    (>= (template-pos-piece-index pos) piece-count)))

(: template-indexed-allowed-ids
   (-> RegexMachine (Vectorof TemplatePiece) template-state (Option TokenIds)))
(define (template-indexed-allowed-ids machine pieces state)
  (define maybe-chars (template-state-first-chars pieces state))
  (and maybe-chars
       (let ([candidate-ids
              (token-ids-for-first-chars machine maybe-chars)])
         (for/list : TokenIds
                   ([id (in-list candidate-ids)]
                    #:when (regex-step machine state id))
           id))))

(: template-state-first-chars
   (-> (Vectorof TemplatePiece) template-state (Option (Listof Char))))
(define (template-state-first-chars pieces state)
  (let loop ([positions : (Listof template-pos) (template-state-positions state)]
             [chars : (Listof Char) '()])
    (cond
      [(null? positions) (reverse chars)]
      [else
       (define maybe-chars (template-pos-first-chars pieces (car positions)))
       (cond
         [(not maybe-chars) #f]
         [else (loop (cdr positions) (append-unique-chars maybe-chars chars))])])))

(: template-pos-first-chars (-> (Vectorof TemplatePiece) template-pos (Option (Listof Char))))
(define (template-pos-first-chars pieces pos)
  (define piece-count (vector-length pieces))
  (define index (template-pos-piece-index pos))
  (cond
    [(>= index piece-count) '()]
    [else
     (define piece (vector-ref pieces index))
     (cond
       [(template-literal? piece)
        (define text (template-literal-text piece))
        (define offset (template-pos-offset pos))
        (if (< offset (string-length text))
            (list (string-ref text offset))
            '())]
       [(template-span? piece)
        (if (< (template-pos-offset pos) (template-span-max-count piece))
            (class-finite-chars (template-span-class piece))
            '())])]))

(: class-finite-chars (-> r-class (Option (Listof Char))))
(define (class-finite-chars c)
  (and (not (r-class-negated? c))
       (let loop ([ranges : (Listof (Pairof Char Char)) (r-class-ranges c)]
                  [chars : (Listof Char) '()]
                  [count : Natural 0])
         (cond
           [(null? ranges) (reverse chars)]
           [else
            (define range (car ranges))
            (define start (char->integer (car range)))
            (define end (char->integer (cdr range)))
            (define range-count (assert (add1 (- end start)) exact-nonnegative-integer?))
            (if (> (+ count range-count) 128)
                #f
                (loop (cdr ranges)
                      (append (range->chars start end) chars)
                      (+ count range-count)))]))))

(: range->chars (-> Integer Integer (Listof Char)))
(define (range->chars start end)
  (for/list : (Listof Char) ([code (in-range start (add1 end))])
    (integer->char code)))

(: append-unique-chars (-> (Listof Char) (Listof Char) (Listof Char)))
(define (append-unique-chars new-chars chars)
  (for/fold ([acc : (Listof Char) chars])
            ([ch (in-list new-chars)])
    (if (char-member? ch acc) acc (cons ch acc))))

(: char-member? (-> Char (Listof Char) Boolean))
(define (char-member? ch chars)
  (for/or : Boolean ([candidate (in-list chars)])
    (char=? ch candidate)))

(: token-ids-for-first-chars (-> RegexMachine (Listof Char) TokenIds))
(define (token-ids-for-first-chars machine chars)
  (define index (regex-machine-first-char-index machine))
  (define empty-ids (regex-machine-empty-token-ids machine))
  (sort-token-ids
   (for/fold ([ids : TokenIds empty-ids])
             ([ch (in-list chars)])
     (append (hash-ref index ch (lambda () (ann '() TokenIds))) ids))))

(: sort-token-ids (-> TokenIds TokenIds))
(define (sort-token-ids ids)
  (sort ids <))

(: ast->nfa (-> RegexAst nfa))
(define (ast->nfa ast)
  (define frag (compile-fragment ast 0))
  (define size (fragment-next-id frag))
  (define adj : (Vectorof (Listof nfa-edge))
    (make-vector size (ann '() (Listof nfa-edge))))
  (for ([edge (in-list (fragment-edges frag))])
    (define from (raw-edge-from edge))
    (vector-set! adj from
                 (cons (nfa-edge (raw-edge-label edge) (raw-edge-to edge))
                       (vector-ref adj from))))
  (define closures : (Vectorof (Option NfaState))
    (make-vector size #f))
  (define accept-mask (state-bit (fragment-accept frag)))
  (define consuming-state-mask
    (for/fold ([mask : NfaState 0])
              ([state : Natural (in-range size)])
      (if (for/or : Boolean ([edge (in-list (vector-ref adj state))])
            (and (nfa-edge-label edge) #t))
          (bitwise-ior mask (state-bit state))
          mask)))
  (nfa (fragment-start frag)
       (fragment-accept frag)
       adj
       closures
       accept-mask
       consuming-state-mask))

(: compile-fragment (-> RegexAst Natural fragment))
(define (compile-fragment ast next-id)
  (cond
    [(r-empty? ast)
     (fragment next-id (add1 next-id) '() (+ next-id 2))]
    [(r-eps? ast)
     (define s next-id)
     (define a (add1 s))
     (fragment s a (list (raw-edge s #f a)) (+ next-id 2))]
    [(r-class? ast)
     (define s next-id)
     (define a (add1 s))
     (fragment s a (list (raw-edge s ast a)) (+ next-id 2))]
    [(r-cat? ast)
     (define left (compile-fragment (r-cat-left ast) next-id))
     (define right (compile-fragment (r-cat-right ast) (fragment-next-id left)))
     (fragment (fragment-start left)
               (fragment-accept right)
               (append (fragment-edges left)
                       (fragment-edges right)
                       (list (raw-edge (fragment-accept left) #f (fragment-start right))))
               (fragment-next-id right))]
    [(r-alt? ast)
     (define left (compile-fragment (r-alt-left ast) (+ next-id 2)))
     (define right (compile-fragment (r-alt-right ast) (fragment-next-id left)))
     (define s next-id)
     (define a (add1 next-id))
     (fragment s a
               (append (fragment-edges left)
                       (fragment-edges right)
                       (list (raw-edge s #f (fragment-start left))
                             (raw-edge s #f (fragment-start right))
                             (raw-edge (fragment-accept left) #f a)
                             (raw-edge (fragment-accept right) #f a)))
               (fragment-next-id right))]
    [(r-star? ast)
     (define body (compile-fragment (r-star-body ast) (+ next-id 2)))
     (define s next-id)
     (define a (add1 next-id))
     (fragment s a
               (append (fragment-edges body)
                       (list (raw-edge s #f a)
                             (raw-edge s #f (fragment-start body))
                             (raw-edge (fragment-accept body) #f (fragment-start body))
                             (raw-edge (fragment-accept body) #f a)))
               (fragment-next-id body))]
    [(r-repeat? ast)
     (compile-fragment
      (expand-repeat-range (r-repeat-body ast)
                           (r-repeat-min-count ast)
                           (r-repeat-max-count ast))
      next-id)]))

(: state-bit (-> Natural NfaState))
(define (state-bit state)
  (assert (arithmetic-shift 1 state) exact-nonnegative-integer?))

(: closure-for-state (-> nfa Natural NfaState))
(define (closure-for-state graph state)
  (define cache (nfa-epsilon-closures graph))
  (define cached (vector-ref cache state))
  (cond
    [cached cached]
    [else
     (define computed (epsilon-closure (nfa-adj graph) state))
     (vector-set! cache state computed)
     computed]))

(: epsilon-closure (-> (Vectorof (Listof nfa-edge)) Natural NfaState))
(define (epsilon-closure adj start)
  (let loop ([pending : (Listof Natural) (list start)] [seen : NfaState 0])
    (cond
      [(null? pending) seen]
      [else
       (define current (car pending))
       (define bit (state-bit current))
       (if (not (zero? (bitwise-and seen bit)))
           (loop (cdr pending) seen)
           (let ([next-pending
                  (for/fold ([acc : (Listof Natural) (cdr pending)])
                            ([edge (in-list (vector-ref adj current))]
                             #:when (not (nfa-edge-label edge)))
                    (cons (nfa-edge-to edge) acc))])
             (loop next-pending (bitwise-ior seen bit))))])))

(: move-char (-> RegexMachine nfa NfaState Char NfaState))
(define (move-char machine graph state ch)
  (define key (cons state ch))
  (define cache (regex-machine-char-cache machine))
  (cond
    [(hash-has-key? cache key) (hash-ref cache key)]
    [else
     (define next : NfaState
       (let loop ([remaining : NfaState (bitwise-and state (nfa-consuming-state-mask graph))]
                  [targets : NfaState 0])
         (cond
           [(zero? remaining) targets]
           [else
            (define lowest-bit
              (assert (bitwise-and remaining (- remaining)) exact-nonnegative-integer?))
            (define index
              (assert (sub1 (integer-length lowest-bit)) exact-nonnegative-integer?))
            (define rest
              (assert (bitwise-and remaining (sub1 remaining)) exact-nonnegative-integer?))
            (define next-targets
              (for/fold ([inner-targets : NfaState targets])
                        ([edge (in-list (vector-ref (nfa-adj graph) index))])
                (define label (nfa-edge-label edge))
                (if (and label (class-contains? label ch))
                    (bitwise-ior inner-targets
                                 (closure-for-state graph (nfa-edge-to edge)))
                    inner-targets)))
            (loop rest next-targets)])))
     (hash-set! cache key next)
     next]))

(: class-contains? (-> r-class Char Boolean))
(define (class-contains? c ch)
  (define inside?
    (for/or : Boolean ([range (in-list (r-class-ranges c))])
      (and (char<=? (car range) ch)
           (char<=? ch (cdr range)))))
  (if (r-class-negated? c) (not inside?) inside?))

(: alt (-> RegexAst RegexAst RegexAst))
(define (alt a b)
  (cond
    [(r-empty? a) b]
    [(r-empty? b) a]
    [(equal? a b) a]
    [else (r-alt a b)]))

(: cat (-> RegexAst RegexAst RegexAst))
(define (cat a b)
  (cond
    [(or (r-empty? a) (r-empty? b)) (r-empty)]
    [(r-eps? a) b]
    [(r-eps? b) a]
    [else (r-cat a b)]))

(: star (-> RegexAst RegexAst))
(define (star r)
  (cond
    [(or (r-empty? r) (r-eps? r)) (r-eps)]
    [(r-star? r) r]
    [else (r-star r)]))

(: optional (-> RegexAst RegexAst))
(define (optional r) (alt (r-eps) r))

(: repeat-range (-> RegexAst Natural (Option Natural) RegexAst))
(define (repeat-range r min-count max-count)
  (r-repeat r min-count max-count))

(: expand-repeat-range (-> RegexAst Natural (Option Natural) RegexAst))
(define (expand-repeat-range r min-count max-count)
  (define required
    (for/fold ([acc : RegexAst (r-eps)])
              ([_ (in-range min-count)])
      (cat acc r)))
  (cond
    [(not max-count) (cat required (star r))]
    [else
     (define extra (- max-count min-count))
     (for/fold ([acc : RegexAst required])
               ([_ (in-range extra)])
       (cat acc (optional r)))]))

(struct parser ([source : String] [pos : Natural]) #:transparent)

(: parse-regex (-> String RegexAst))
(define (parse-regex source)
  (define-values (ast p) (parse-alt (parser source 0)))
  (unless (= (parser-pos p) (string-length source))
    (error 'rx "unexpected regex input at offset ~a in ~s" (parser-pos p) source))
  ast)

(: parse-alt (-> parser (Values RegexAst parser)))
(define (parse-alt p0)
  (define-values (first p1) (parse-concat p0))
  (let loop : (Values RegexAst parser) ([acc : RegexAst first] [p : parser p1])
    (if (peek-char=? p #\|)
        (let-values ([(rhs p2) (parse-concat (advance p))])
          (loop (alt acc rhs) p2))
        (values acc p))))

(: parse-concat (-> parser (Values RegexAst parser)))
(define (parse-concat p0)
  (let loop : (Values RegexAst parser) ([parts : (Listof RegexAst) '()] [p : parser p0])
    (cond
      [(or (at-end? p) (peek-char=? p #\)) (peek-char=? p #\|))
       (values (foldl (lambda ([part : RegexAst] [acc : RegexAst]) (cat acc part))
                      (r-eps)
                      (reverse parts))
               p)]
      [else
       (define-values (piece p1) (parse-repeat p))
       (loop (cons piece parts) p1)])))

(: parse-repeat (-> parser (Values RegexAst parser)))
(define (parse-repeat p0)
  (define-values (atom p1) (parse-atom p0))
  (cond
    [(peek-char=? p1 #\?) (values (optional atom) (advance p1))]
    [(peek-char=? p1 #\*) (values (star atom) (advance p1))]
    [(peek-char=? p1 #\+) (values (cat atom (star atom)) (advance p1))]
    [(peek-char=? p1 #\{)
     (define-values (min-count max-count p2) (parse-braces (advance p1)))
     (values (repeat-range atom min-count max-count) p2)]
    [else (values atom p1)]))

(: parse-atom (-> parser (Values RegexAst parser)))
(define (parse-atom p)
  (cond
    [(at-end? p) (error 'rx "unexpected end of regex")]
    [(peek-char=? p #\()
     (define after-open (advance p))
     (when (peek-char=? after-open #\?)
       (error 'rx "unsupported regex group syntax near offset ~a in ~s"
              (parser-pos p)
              (parser-source p)))
     (define-values (body p1) (parse-alt after-open))
     (unless (peek-char=? p1 #\))
       (error 'rx "unclosed group in ~s" (parser-source p)))
     (values body (advance p1))]
    [(peek-char=? p #\[) (parse-class (advance p))]
    [(peek-char=? p #\.) (values (r-class '() #t) (advance p))]
    [(peek-char=? p #\\) (parse-escape (advance p))]
    [else
     (define ch (current-char p))
     (cond
       [(or (char=? ch #\^) (char=? ch #\$))
        (error 'rx "unsupported regex anchor ~a in ~s" ch (parser-source p))]
       [(member ch '(#\) #\] #\{ #\} #\? #\* #\+ #\|))
        (error 'rx "unexpected metacharacter ~a in ~s" ch (parser-source p))]
       [else (values (literal-char ch) (advance p))])]))

(: parse-escape (-> parser (Values RegexAst parser)))
(define (parse-escape p)
  (when (at-end? p)
    (error 'rx "dangling escape"))
  (define ch (current-char p))
  (cond
    [(char-numeric? ch) (error 'rx "unsupported backreference \\~a" ch)]
    [(char=? ch #\d) (values digit-class (advance p))]
    [(char=? ch #\s) (values space-class (advance p))]
    [(char=? ch #\S) (values (negate-class space-class) (advance p))]
    [(char=? ch #\w) (values word-class (advance p))]
    [(char-alphabetic? ch) (error 'rx "unsupported regex escape \\~a" ch)]
    [else (values (literal-char ch) (advance p))]))

(: parse-class (-> parser (Values RegexAst parser)))
(define (parse-class p0)
  (define negated? (peek-char=? p0 #\^))
  (define p-start (if negated? (advance p0) p0))
  (let loop : (Values RegexAst parser) ([ranges : (Listof (Pairof Char Char)) '()]
                                        [p : parser p-start])
    (cond
      [(at-end? p) (error 'rx "unclosed character class in ~s" (parser-source p0))]
      [(peek-char=? p #\])
       (when (null? ranges)
         (error 'rx "empty character class in ~s" (parser-source p0)))
       (values (r-class (reverse ranges) negated?) (advance p))]
      [else
       (define-values (ranges1 p1) (class-item p))
       (loop (append (reverse ranges1) ranges) p1)])))

(: class-item (-> parser (Values (Listof (Pairof Char Char)) parser)))
(define (class-item p)
  (cond
    [(peek-char=? p #\\)
     (define p1 (advance p))
     (when (at-end? p1) (error 'rx "dangling escape in class"))
     (define ch (current-char p1))
     (cond
       [(char=? ch #\d) (values digit-ranges (advance p1))]
       [(char=? ch #\s) (values space-ranges (advance p1))]
       [(char=? ch #\w) (values word-ranges (advance p1))]
       [(char=? ch #\S) (error 'rx "\\S inside character classes is unsupported")]
       [(char-alphabetic? ch) (error 'rx "unsupported regex escape \\~a in class" ch)]
       [else (maybe-range ch (advance p1))])]
    [else (maybe-range (current-char p) (advance p))]))

(: maybe-range (-> Char parser (Values (Listof (Pairof Char Char)) parser)))
(define (maybe-range start p)
  (cond
    [(and (peek-char=? p #\-)
          (not (at-end? (advance p)))
          (not (peek-char=? (advance p) #\])))
     (define end (current-char (advance p)))
     (when (char<? end start)
       (error 'rx "descending character range ~a-~a" start end))
     (values (list (cons start end)) (advance (advance p)))]
    [else (values (list (cons start start)) p)]))

(: parse-braces (-> parser (Values Natural (Option Natural) parser)))
(define (parse-braces p0)
  (define-values (min-count p1) (parse-natural p0))
  (cond
    [(peek-char=? p1 #\}) (values min-count min-count (advance p1))]
    [(peek-char=? p1 #\,)
     (define p2 (advance p1))
     (if (peek-char=? p2 #\})
         (values min-count #f (advance p2))
         (let-values ([(max-count p3) (parse-natural p2)])
           (unless (peek-char=? p3 #\})
             (error 'rx "unclosed repetition in ~s" (parser-source p0)))
           (when (< max-count min-count)
             (error 'rx "repetition maximum is smaller than minimum"))
           (values min-count max-count (advance p3))))]
    [else (error 'rx "expected } or , in repetition in ~s" (parser-source p0))]))

(: parse-natural (-> parser (Values Natural parser)))
(define (parse-natural p0)
  (let loop : (Values Natural parser) ([n : Natural 0] [seen? : Boolean #f] [p : parser p0])
    (if (and (not (at-end? p)) (char-numeric? (current-char p)))
        (loop (assert (+ (* n 10)
                         (- (char->integer (current-char p)) (char->integer #\0)))
                      exact-nonnegative-integer?)
              #t
              (advance p))
        (begin
          (unless seen?
            (error 'rx "expected integer repetition count in ~s" (parser-source p0)))
          (values n p)))))

(: digit-ranges (Listof (Pairof Char Char)))
(define digit-ranges (list (cons #\0 #\9)))
(: space-ranges (Listof (Pairof Char Char)))
(define space-ranges (list (cons #\space #\space)
                           (cons #\tab #\tab)
                           (cons #\newline #\newline)
                           (cons #\return #\return)))
(: word-ranges (Listof (Pairof Char Char)))
(define word-ranges (list (cons #\A #\Z) (cons #\a #\z)
                          (cons #\0 #\9) (cons #\_ #\_)))
(: digit-class RegexAst)
(define digit-class (r-class digit-ranges #f))
(: space-class RegexAst)
(define space-class (r-class space-ranges #f))
(: word-class RegexAst)
(define word-class (r-class word-ranges #f))

(: literal-char (-> Char RegexAst))
(define (literal-char ch)
  (r-class (list (cons ch ch)) #f))

(: negate-class (-> RegexAst RegexAst))
(define (negate-class r)
  (cond
    [(r-class? r) (r-class (r-class-ranges r) (not (r-class-negated? r)))]
    [else (error 'rx "cannot negate non-class")]))

(: at-end? (-> parser Boolean))
(define (at-end? p)
  (>= (parser-pos p) (string-length (parser-source p))))

(: current-char (-> parser Char))
(define (current-char p)
  (string-ref (parser-source p) (parser-pos p)))

(: peek-char=? (-> parser Char Boolean))
(define (peek-char=? p ch)
  (and (not (at-end? p))
       (char=? (current-char p) ch)))

(: advance (-> parser parser))
(define (advance p)
  (parser (parser-source p) (add1 (parser-pos p))))
