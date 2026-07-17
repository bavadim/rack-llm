#lang typed/racket/base

(require racket/list racket/port)
(require/typed "weak-json.rkt"
  [read-json-file (-> Path-String Any)] [write-json-file (-> Any Path-String Void)])

(provide weak-model-arity weak-model-fingerprint weak-model-diagnostics
         fit-weak-model weak-posterior weak-posterior/row save-weak-model load-weak-model)

(define-type Label Integer)
(define-type Row (Vectorof Label))
(define-type Matrix (Vectorof (Vectorof Real)))
(struct weak-model
  ([arity : Natural] [prior : Real] [bad : Matrix] [good : Matrix]
   [fingerprint : String] [diagnostics : (Immutable-HashTable Symbol Any)])
  #:transparent)

(: fingerprint (-> Any String))
(define (fingerprint datum)
  (apply string-append
         (for/list : (Listof String)
           ([b (in-bytes (sha256-bytes (open-input-bytes
                                        (call-with-output-bytes
                                         (lambda ([out : Output-Port]) (write datum out))))))])
           (define h (number->string b 16))
           (if (= (string-length h) 1) (string-append "0" h) h))))

(: labels (-> Any Row))
(define (labels value)
  (define xs (cond [(vector? value) (vector->list value)]
                   [(list? value) value]
                   [else (raise-argument-error 'weak-labels "vector? or list?" value)]))
  (for ([x (in-list xs)])
    (unless (member x '(-1 0 1)) (error 'weak-labels "invalid weak label ~a" x)))
  (vector->immutable-vector
   (list->vector (map (lambda ([x : Any]) (assert x exact-integer?)) xs))))

(: clamp (-> Real Real))
(define (clamp x) (max 1e-12 (min (- 1.0 1e-12) x)))
(: sigmoid (-> Real Real))
(define (sigmoid x) (if (>= x 0.0) (/ 1.0 (+ 1.0 (exp (- x))))
                        (let ([e (exp x)]) (/ e (+ 1.0 e)))))
(: rlog (-> Real Real))
(define (rlog x) (assert (log x) real?))
(: label-index (-> Label Natural))
(define (label-index x) (case x [(-1) 0] [(0) 1] [(1) 2]
                          [else (error 'weak-model "invalid label ~a" x)]))
(: probability (-> (Vectorof Real) Label Real))
(define (probability ps x) (vector-ref ps (label-index x)))
(: normalize (-> (Vectorof Real) Real (Vectorof Real)))
(define (normalize counts total)
  (for/vector : (Vectorof Real) ([x (in-vector counts)]) (clamp (/ x total))))
(: mean (-> (Vectorof Real) Real))
(define (mean ps) (- (vector-ref ps 2) (vector-ref ps 0)))

(: evaluate (-> (Listof Row) Real Matrix Matrix (Values Real (Vectorof Real))))
(define (evaluate rows prior bad good)
  (define responsibilities : (Vectorof Real) (make-vector (length rows) 0.5))
  (define objective : Real 0.0)
  (for ([row (in-list rows)] [k : Natural (in-naturals)])
    (define l0 (+ (rlog (- 1.0 prior))
                  (for/sum : Real ([x (in-vector row)] [p (in-vector bad)])
                    (rlog (probability p x)))))
    (define l1 (+ (rlog prior)
                  (for/sum : Real ([x (in-vector row)] [p (in-vector good)])
                    (rlog (probability p x)))))
    (define top (max l0 l1))
    (set! objective (+ objective top (rlog (+ (exp (- l0 top)) (exp (- l1 top))))))
    (vector-set! responsibilities k (sigmoid (- l1 l0))))
  (values objective responsibilities))

(struct fit ([prior : Real] [bad : Matrix] [good : Matrix]
             [objective : Real] [iterations : Natural] [converged? : Boolean]))
(: fit-once (-> (Listof Row) Natural Real Real Real Pseudo-Random-Generator fit))
(define (fit-once rows limit tolerance pseudocount separation rng)
  (define n (length rows))
  (define m (vector-length (car rows)))
  (define prior : Real
    (parameterize ([current-pseudo-random-generator rng])
      (sigmoid (* 0.25 (- (* 2.0 (random)) 1.0)))))
  (define bad : Matrix (for/vector : Matrix ([_ (in-range m)])
                         (ann (vector 0.25 0.5 0.25) (Vectorof Real))))
  (define good : Matrix (for/vector : Matrix ([_ (in-range m)])
                          (ann (vector 0.25 0.5 0.25) (Vectorof Real))))
  (for ([i : Natural (in-range m)])
    (define counts : (Vectorof Real) (vector pseudocount pseudocount pseudocount))
    (for ([row (in-list rows)])
      (define j (label-index (vector-ref row i)))
      (vector-set! counts j (add1 (vector-ref counts j))))
    (define base (normalize counts (+ n (* 3.0 pseudocount))))
    (define tilt (+ separation
                    (parameterize ([current-pseudo-random-generator rng])
                      (* 0.25 (- (* 2.0 (random)) 1.0)))))
    (for ([target (in-list (list good bad))] [sign (in-list '(1.0 -1.0))])
      (define raw
        (for/vector : (Vectorof Real) ([p (in-vector base)] [x (in-list '(-1.0 0.0 1.0))])
          (* p (exp (* sign tilt x)))))
      (vector-set! target i (normalize raw (for/sum : Real ([x (in-vector raw)]) x)))))
  (let loop ([iteration : Natural 0] [prior prior] [bad bad] [good good] [previous : Real -inf.0])
    (define-values (objective r) (evaluate rows prior bad good))
    (define converged? (and (> iteration 0)
                            (<= (/ (abs (- objective previous)) (max 1.0 (abs previous))) tolerance)))
    (cond [(or converged? (>= iteration limit) (< objective (- previous 1e-8)))
           (fit prior bad good objective iteration converged?)]
          [else
           (define good-total (for/sum : Real ([x (in-vector r)]) x))
           (define bad-total (- n good-total))
           (define next-bad : Matrix (for/vector : Matrix ([_ (in-range m)])
                                       (ann (vector 0.25 0.5 0.25) (Vectorof Real))))
           (define next-good : Matrix (for/vector : Matrix ([_ (in-range m)])
                                        (ann (vector 0.25 0.5 0.25) (Vectorof Real))))
           (for ([i : Natural (in-range m)])
             (define bc : (Vectorof Real) (vector pseudocount pseudocount pseudocount))
             (define gc : (Vectorof Real) (vector pseudocount pseudocount pseudocount))
             (for ([row (in-list rows)] [weight (in-vector r)])
               (define j (label-index (vector-ref row i)))
               (vector-set! gc j (+ (vector-ref gc j) weight))
               (vector-set! bc j (+ (vector-ref bc j) (- 1.0 weight))))
             (define b (normalize bc (+ bad-total (* 3.0 pseudocount))))
             (define g (normalize gc (+ good-total (* 3.0 pseudocount))))
             (if (< (mean g) (mean b))
                 (let* ([pooled (for/vector : (Vectorof Real) ([x (in-vector bc)] [y (in-vector gc)]) (+ x y))]
                        [neutral (normalize pooled (+ n (* 6.0 pseudocount)))])
                   (vector-set! next-bad i neutral) (vector-set! next-good i neutral))
                 (begin (vector-set! next-bad i b) (vector-set! next-good i g))))
           (loop (add1 iteration)
                 (clamp (/ (+ good-total pseudocount) (+ n (* 2.0 pseudocount))))
                 next-bad next-good objective)])))

(: fit-weak-model
   (->* ((Listof Any)) (#:max-iterations Positive-Integer #:tolerance Real
                         #:pseudocount Real #:restarts Positive-Integer #:seed Integer)
        weak-model))
(define (fit-weak-model observations #:max-iterations [limit 200] #:tolerance [tolerance 1e-7]
                        #:pseudocount [pseudocount 1.0] #:restarts [restarts 8] #:seed [seed 0])
  (when (null? observations) (raise-argument-error 'fit-weak-model "non-empty observations" observations))
  (define rows (map labels observations))
  (define m (vector-length (car rows)))
  (unless (and (positive? m) (andmap (lambda ([r : Row]) (= m (vector-length r))) rows))
    (error 'fit-weak-model "incompatible or empty weak-label vectors"))
  (define informative
    (for/list : (Listof Natural) ([i : Natural (in-range m)]
                                  #:when (> (length (remove-duplicates
                                                     (map (lambda ([r : Row]) (vector-ref r i)) rows))) 1)) i))
  (when (< (length informative) 3) (error 'fit-weak-model "unidentifiable weak model"))
  (for* ([a (in-list informative)] [b (in-list informative)] #:when (< a b))
    (when (andmap (lambda ([r : Row]) (= (vector-ref r a) (vector-ref r b))) rows)
      (error 'fit-weak-model "unidentifiable weak model: duplicate rule columns ~a and ~a" a b)))
  (define fits
    (for/list : (Listof fit) ([restart : Natural (in-range restarts)])
      (define rng (make-pseudo-random-generator))
      (parameterize ([current-pseudo-random-generator rng]) (random-seed (add1 (abs (+ seed restart)))))
      (fit-once rows limit tolerance pseudocount (+ 0.75 (* 0.05 restart)) rng)))
  (define converged (filter fit-converged? fits))
  (when (null? converged) (error 'fit-weak-model "no EM restart converged"))
  (define best (argmax fit-objective converged))
  (define active
    (for/sum : Natural ([b (in-vector (fit-bad best))] [g (in-vector (fit-good best))])
      (if (>= (for/sum : Real ([x (in-vector b)] [y (in-vector g)]) (abs (- y x))) 1e-3) 1 0)))
  (when (< active 3) (error 'fit-weak-model "unidentifiable weak model: fitted solution collapsed"))
  (define form (list 'rack-llm-weak-model 6 m (fit-prior best)
                     (vector->list (fit-bad best)) (vector->list (fit-good best))))
  (weak-model m (fit-prior best) (fit-bad best) (fit-good best) (fingerprint form)
              (hash 'iterations (fit-iterations best) 'objective (fit-objective best)
                    'observations (length rows) 'rules m 'active-rules active
                    'neutralized-rules (- m active))))

(: weak-posterior/row (-> weak-model Row Real))
(define (weak-posterior/row model row)
  (sigmoid (+ (rlog (/ (weak-model-prior model) (- 1.0 (weak-model-prior model))))
              (for/sum : Real ([x (in-vector row)] [b (in-vector (weak-model-bad model))]
                               [g (in-vector (weak-model-good model))])
                (rlog (/ (probability g x) (probability b x)))))))

(: weak-posterior (-> weak-model Any Real))
(define (weak-posterior model value)
  (define row (labels value))
  (unless (= (vector-length row) (weak-model-arity model))
    (error 'weak-posterior "weak-label width does not match model"))
  (weak-posterior/row model row))

(: json-safe (-> Any Any))
(define (json-safe x)
  (cond [(and (real? x) (exact? x)) (exact->inexact x)]
        [(hash? x) (for/hash ([(k v) (in-hash x)]) (values k (json-safe v)))]
        [(vector? x) (map json-safe (vector->list x))]
        [(list? x) (map json-safe x)] [else x]))
(: save-weak-model (-> weak-model Path-String Void))
(define (save-weak-model m path)
  (write-json-file
   (hash 'format "rack-llm-weak-model" 'version 6 'arity (weak-model-arity m)
         'fingerprint (weak-model-fingerprint m) 'prior_good (weak-model-prior m)
         'p_label_bad (json-safe (weak-model-bad m)) 'p_label_good (json-safe (weak-model-good m))
         'diagnostics (json-safe (weak-model-diagnostics m))) path))

(: matrix (-> Symbol Any Matrix))
(define (matrix who value)
  (unless (list? value) (raise-argument-error who "probability matrix" value))
  (for/vector : Matrix ([row (in-list (assert value list?))])
    (unless (and (list? row) (= (length row) 3) (andmap real? row))
      (raise-argument-error who "rows of three probabilities" row))
    (define result : (Vectorof Real)
      (list->vector (map (lambda ([x : Any]) (assert x real?)) (assert row list?))))
    (unless (and (andmap (lambda ([x : Real]) (and (> x 0.0) (< x 1.0))) (vector->list result))
                 (<= (abs (- (for/sum : Real ([x (in-vector result)]) x) 1.0)) 1e-8))
      (error who "invalid probability row"))
    result))
(: load-weak-model (-> Path-String weak-model))
(define (load-weak-model path)
  (define payload (read-json-file path))
  (unless (hash? payload) (error 'load-weak-model "model file is not a JSON object"))
  (define h (assert payload hash?))
  (define (field [key : Symbol]) (hash-ref h key (lambda () (error 'load-weak-model "missing ~a" key))))
  (unless (and (equal? (field 'format) "rack-llm-weak-model") (equal? (field 'version) 6))
    (error 'load-weak-model "unsupported weak-model format or version"))
  (define arity (assert (field 'arity) exact-nonnegative-integer?))
  (define prior (assert (field 'prior_good) real?))
  (define bad (matrix 'load-weak-model (field 'p_label_bad)))
  (define good (matrix 'load-weak-model (field 'p_label_good)))
  (unless (and (> prior 0.0) (< prior 1.0) (= arity (vector-length bad) (vector-length good)))
    (error 'load-weak-model "inconsistent weak-model dimensions"))
  (for ([b (in-vector bad)] [g (in-vector good)])
    (when (< (mean g) (mean b)) (error 'load-weak-model "signed orientation violation")))
  (define form (list 'rack-llm-weak-model 6 arity prior (vector->list bad) (vector->list good)))
  (define fp (fingerprint form))
  (unless (equal? fp (field 'fingerprint)) (error 'load-weak-model "weak-model fingerprint mismatch"))
  (define d (field 'diagnostics))
  (weak-model arity prior bad good fp
              (if (hash? d) (for/hash : (Immutable-HashTable Symbol Any)
                              ([(k v) (in-hash d)] #:when (symbol? k)) (values k v)) (hash))))
