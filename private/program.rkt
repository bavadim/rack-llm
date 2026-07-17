#lang racket/base

(require racket/list racket/match racket/string
         "domain.rkt" "regex.rkt")

(provide lit ere seq choice repeat text with-rules positive negative
         compile-program program-rule-count program-initial program-step
         program-accepting? program-dead? program-domain program-observe)

;; Public syntax.  The compiled VM below is deliberately independent of the
;; surface structs: compilation validates once and does not retain the AST.
(struct literal (text) #:transparent)
(struct regular (pattern) #:transparent)
(struct sequence (items) #:transparent)
(struct alternatives (items) #:transparent)
(struct repetition (min max item) #:transparent)
(struct any-text (max) #:transparent)
(struct scoped (child rules) #:transparent)
(struct weak-rule (polarity pattern) #:transparent)

(define (program? v)
  (or (literal? v) (regular? v) (sequence? v) (alternatives? v)
      (repetition? v) (any-text? v) (scoped? v)))
(define (lit s) (unless (string? s) (raise-argument-error 'lit "string?" s)) (literal s))
(define (ere s) (regular (parse-ere-pattern s)))
(define (programs who xs)
  (unless (and (pair? xs) (andmap program? xs))
    (raise-argument-error who "one or more programs" xs))
  xs)
(define (seq . xs) (sequence (programs 'seq xs)))
(define (choice . xs) (alternatives (programs 'choice xs)))
(define (repeat min max p)
  (unless (and (exact-nonnegative-integer? min) (exact-nonnegative-integer? max)
               (<= min max) (program? p))
    (raise-arguments-error 'repeat "expected 0 <= min <= max and a program"
                           "min" min "max" max "program" p))
  (repetition min max p))
(define (text max)
  (unless (exact-nonnegative-integer? max)
    (raise-argument-error 'text "exact-nonnegative-integer?" max))
  (any-text max))
(define (rule who polarity p)
  (unless (or (literal? p) (regular? p))
    (raise-argument-error who "lit or ere" p))
  (weak-rule polarity p))
(define (positive p) (rule 'positive 1 p))
(define (negative p) (rule 'negative -1 p))
(define (with-rules p . rs)
  (unless (program? p) (raise-argument-error 'with-rules "program?" p))
  (unless (andmap weak-rule? rs)
    (raise-argument-error 'with-rules "positive/negative rules" rs))
  (if (null? rs) p (scoped p rs)))

;; Compiled regular-language VM.  A run is a continuation stack plus completed
;; weak-rule spans.  Epsilon expansion handles sequence, choice, repetition and
;; scope boundaries uniformly, so there are no combinator-specific state types.
(struct c-lit (ids) #:transparent)
(struct c-regex (machine) #:transparent)
(struct c-text (max) #:transparent)
(struct c-seq (items) #:transparent)
(struct c-choice (items) #:transparent)
(struct c-repeat (min max item) #:transparent)
(struct c-scope (child slots) #:transparent)
(struct more (min max item) #:transparent)
(struct close-scope (slots start) #:transparent)
(struct a-lit (ids pos) #:transparent)
(struct a-regex (machine state) #:transparent)
(struct a-text (count max) #:transparent)
(struct span (slot start end) #:transparent)
(struct run (todo spans) #:transparent)
(struct state (runs position) #:transparent)
(struct matcher (polarity literal regex) #:transparent)
(struct compiled-program (root rules) #:transparent)

(define (compile-program ast tokenize vocabulary)
  (define rules '())
  (define (add-rule! r)
    (define p (weak-rule-pattern r))
    (define slot (length rules))
    (define m (if (literal? p)
                  (matcher (weak-rule-polarity r) (literal-text p) #f)
                  (matcher (weak-rule-polarity r) #f
                           (make-text-regex (regular-pattern p)))))
    (set! rules (append rules (list m)))
    slot)
  ;; Returns compiled node, nullable?, and contains-text?.
  (define (walk p path)
    (match p
      [(literal s)
       (define ids (list->vector (tokenize s)))
       (values (c-lit ids) (zero? (vector-length ids)) #f)]
      [(regular pattern)
       (define machine (make-hard-regex pattern vocabulary))
       (values (c-regex machine) (regex-state-accepting? (regex-start machine)) #f)]
      [(any-text max) (values (c-text max) #t #t)]
      [(alternatives xs)
       (define triples (for/list ([x (in-list xs)] [i (in-naturals)])
                         (call-with-values (lambda () (walk x (format "~a/choice[~a]" path i))) list)))
       (values (c-choice (map car triples)) (ormap cadr triples) (ormap caddr triples))]
      [(sequence xs)
       (define triples (for/list ([x (in-list xs)] [i (in-naturals)])
                         (call-with-values (lambda () (walk x (format "~a/seq[~a]" path i))) list)))
       (for ([triple (in-list (drop-right triples 1))] [i (in-naturals)])
         (when (caddr triple) (error 'compile-spec "~a/seq[~a]: text must be in tail position" path i)))
       (values (c-seq (map car triples)) (andmap cadr triples) (ormap caddr triples))]
      [(repetition min max item)
       (define-values (child nullable? has-text?) (walk item (string-append path "/repeat")))
       (when has-text? (error 'compile-spec "~a: text cannot be repeated" path))
       (when nullable? (error 'compile-spec "~a: repeated program must consume a token" path))
       (values (c-repeat min max child) (zero? min) #f)]
      [(scoped child rs)
       ;; Outer rules precede rules nested in the child, matching structural DSL order.
       (define slots (map add-rule! rs))
       (define-values (body nullable? has-text?) (walk child (string-append path "/rules")))
       (values (c-scope body slots) nullable? has-text?)]
      [_ (raise-argument-error 'compile-spec "program?" p)]))
  (define-values (root _nullable _text?) (walk ast "root"))
  (compiled-program root (list->vector rules)))

(define (program-rule-count p) (vector-length (compiled-program-rules p)))

;; Expand epsilon tasks until every returned run is accepting or starts with a
;; consuming active matcher.  Accepting regex/text leaves fork: one branch ends
;; the leaf and another may consume more input.
(define (expand-one r position)
  (match (run-todo r)
    ['() (list r)]
    [(cons (c-seq xs) rest) (expand-one (run (append xs rest) (run-spans r)) position)]
    [(cons (c-choice xs) rest)
     (append-map (lambda (x) (expand-one (run (cons x rest) (run-spans r)) position)) xs)]
    [(cons (c-repeat min max item) rest)
     (expand-one (run (cons (more min max item) rest) (run-spans r)) position)]
    [(cons (more min max item) rest)
     (append (if (zero? min) (expand-one (run rest (run-spans r)) position) '())
             (if (positive? max)
                 (expand-one (run (list* item (more (if (zero? min) 0 (sub1 min)) (sub1 max) item) rest)
                                      (run-spans r)) position)
                 '()))]
    [(cons (c-scope child slots) rest)
     (expand-one (run (list* child (close-scope slots position) rest) (run-spans r)) position)]
    [(cons (close-scope slots start) rest)
     (define spans (append (for/list ([slot (in-list slots)]) (span slot start position))
                           (run-spans r)))
     (expand-one (run rest spans) position)]
    [(cons (c-lit ids) rest)
     (if (zero? (vector-length ids))
         (expand-one (run rest (run-spans r)) position)
         (list (run (cons (a-lit ids 0) rest) (run-spans r))))]
    [(cons (c-regex machine) rest)
     (expand-one (run (cons (a-regex machine (regex-start machine)) rest) (run-spans r)) position)]
    [(cons (c-text max) rest)
     (expand-one (run (cons (a-text 0 max) rest) (run-spans r)) position)]
    [(cons (and active (a-regex _ s)) rest)
     (cons r (if (regex-state-accepting? s)
                 (expand-one (run rest (run-spans r)) position) '()))]
    [(cons (a-text count max) rest)
     (append (if (< count max) (list r) '())
             (expand-one (run rest (run-spans r)) position))]
    [(cons (a-lit _ _) _) (list r)]))

(define (normalize runs position)
  (define seen (make-hash))
  (reverse
   (for*/fold ([unique '()]) ([source (in-list runs)]
                              [r (in-list (expand-one source position))])
     (if (hash-ref seen r #f)
         unique
         (begin (hash-set! seen r #t) (cons r unique))))))
(define (program-initial p)
  (state (normalize (list (run (list (compiled-program-root p)) '())) 0) 0))
(define (program-step st id)
  (define next-position (add1 (state-position st)))
  (define next
    (append-map
     (lambda (r)
       (match (run-todo r)
         [(cons (a-lit ids pos) rest)
          (if (= id (vector-ref ids pos))
              (list (run (if (= (add1 pos) (vector-length ids)) rest
                             (cons (a-lit ids (add1 pos)) rest))
                         (run-spans r))) '())]
         [(cons (a-regex machine s) rest)
          (define n (regex-state-step s id))
          (if n (list (run (cons (a-regex machine n) rest) (run-spans r))) '())]
         [(cons (a-text count max) rest)
          (if (< count max) (list (run (cons (a-text (add1 count) max) rest) (run-spans r))) '())]
         [_ '()]))
     (state-runs st)))
  (state (normalize next next-position) next-position))

(define (program-accepting? st) (ormap (lambda (r) (null? (run-todo r))) (state-runs st)))
(define (program-dead? st) (null? (state-runs st)))
(define (program-domain st)
  (for/fold ([domain domain-none]) ([r (in-list (state-runs st))])
    (match (run-todo r)
      [(cons (a-lit ids pos) _) (domain-union domain (domain-only (list (vector-ref ids pos))))]
      [(cons (a-regex _machine s) _) (domain-union domain (domain-only/vector (regex-allowed s)))]
      [(cons (a-text _ _) _) domain-all]
      [_ domain])))

(define (program-observe p st ids detokenize)
  (unless (program-accepting? st) (error 'observe-token-ids "hard-invalid candidate"))
  (define labels (make-vector (program-rule-count p) 0))
  (define samples (make-hash))
  (for* ([r (in-list (state-runs st))] #:when (null? (run-todo r))
         [sp (in-list (run-spans r))])
    (define m (vector-ref (compiled-program-rules p) (span-slot sp)))
    (define key (cons (span-start sp) (span-end sp)))
    (define sample
      (hash-ref! samples key
                 (lambda ()
                   (detokenize
                    (take (drop ids (car key)) (- (cdr key) (car key)))))))
    (when (if (matcher-literal m) (string-contains? sample (matcher-literal m))
              (regex-text-match? (matcher-regex m) sample))
      (vector-set! labels (span-slot sp) (matcher-polarity m))))
  (vector->immutable-vector labels))
