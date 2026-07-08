#lang typed/racket/base

(require racket/list)

(provide RegexProgram
         RegexMachine
         RegexState
         parse-regex-program
         instantiate-regex-machine
         regex-initial
         regex-step
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

(define-type RegexAst (U r-empty r-eps r-class r-alt r-cat r-star))
(define-type RegexState (Listof Natural))

(struct raw-edge ([from : Natural] [label : (Option r-class)] [to : Natural]) #:transparent)
(struct nfa-edge ([label : (Option r-class)] [to : Natural]) #:transparent)
(struct nfa ([start : Natural] [accept : Natural] [adj : (Vectorof (Listof nfa-edge))]) #:transparent)
(struct fragment
  ([start : Natural]
   [accept : Natural]
   [edges : (Listof raw-edge)]
   [next-id : Natural])
  #:transparent)

(struct regex-program
  ([source : String]
   [nfa : nfa])
  #:transparent)
(define-type RegexProgram regex-program)

(struct regex-machine
  ([program : RegexProgram]
   [token-texts : (Vectorof String)]
   [transition-cache : (Mutable-HashTable (Pairof RegexState TokenId) (Option RegexState))]
   [allowed-cache : (Mutable-HashTable RegexState TokenIds)])
  #:transparent)
(define-type RegexMachine regex-machine)

(: parse-regex-program (-> String RegexProgram))
(define (parse-regex-program source)
  (regex-program source (ast->nfa (parse-regex source))))

(: instantiate-regex-machine (-> RegexProgram (Vectorof String) RegexMachine))
(define (instantiate-regex-machine program token-texts)
  (regex-machine program
                 token-texts
                 (ann (make-hash) (Mutable-HashTable (Pairof RegexState TokenId) (Option RegexState)))
                 (ann (make-hash) (Mutable-HashTable RegexState TokenIds))))

(: regex-initial (-> RegexMachine RegexState))
(define (regex-initial machine)
  (define graph (regex-program-nfa (regex-machine-program machine)))
  (epsilon-closure graph (list (nfa-start graph))))

(: regex-step (-> RegexMachine RegexState TokenId (Option RegexState)))
(define (regex-step machine state id)
  (define key (cons state id))
  (define cache (regex-machine-transition-cache machine))
  (cond
    [(hash-has-key? cache key) (hash-ref cache key)]
    [else
     (define graph (regex-program-nfa (regex-machine-program machine)))
     (define token (vector-ref (regex-machine-token-texts machine) id))
     (define next
       (for/fold ([current : (Option RegexState) state])
                 ([ch (in-string token)])
         (and current
              (let ([moved (move-char graph current ch)])
                (and (pair? moved) moved)))))
     (hash-set! cache key next)
     next]))

(: regex-accepting? (-> RegexMachine RegexState Boolean))
(define (regex-accepting? machine state)
  (define graph (regex-program-nfa (regex-machine-program machine)))
  (and (member (nfa-accept graph) state) #t))

(: regex-terminal? (-> RegexMachine RegexState Boolean))
(define (regex-terminal? machine state)
  (and (regex-accepting? machine state)
       (null? (regex-allowed-ids machine state))))

(: regex-allowed-ids (-> RegexMachine RegexState TokenIds))
(define (regex-allowed-ids machine state)
  (define cache (regex-machine-allowed-cache machine))
  (cond
    [(hash-has-key? cache state) (hash-ref cache state)]
    [else
     (define vocab (regex-machine-token-texts machine))
     (define allowed
       (for/list : TokenIds
                 ([id : Natural (in-range (vector-length vocab))]
                  #:when (regex-step machine state id))
         id))
     (hash-set! cache state allowed)
     allowed]))

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
  (nfa (fragment-start frag) (fragment-accept frag) adj))

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
               (fragment-next-id body))]))

(: epsilon-closure (-> nfa RegexState RegexState))
(define (epsilon-closure graph states)
  (let loop ([pending : RegexState states] [seen : RegexState '()])
    (cond
      [(null? pending) (normalize-state seen)]
      [(member (car pending) seen) (loop (cdr pending) seen)]
      [else
       (define current (car pending))
       (define eps-targets
         (for/list : RegexState
                   ([edge (in-list (vector-ref (nfa-adj graph) current))]
                    #:when (not (nfa-edge-label edge)))
           (nfa-edge-to edge)))
       (loop (append eps-targets (cdr pending)) (cons current seen))])))

(: move-char (-> nfa RegexState Char RegexState))
(define (move-char graph states ch)
  (define direct
    (for/fold ([targets : RegexState '()])
              ([state (in-list states)])
      (append targets
              (for/list : RegexState
                        ([edge (in-list (vector-ref (nfa-adj graph) state))]
                         #:when (let ([label (nfa-edge-label edge)])
                                  (and label (class-contains? label ch))))
                (nfa-edge-to edge)))))
  (if (null? direct) '() (epsilon-closure graph direct)))

(: normalize-state (-> RegexState RegexState))
(define (normalize-state state)
  (sort (remove-duplicates state) <))

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
