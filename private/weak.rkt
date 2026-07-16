#lang typed/racket/base

(require racket/list
         racket/match
         racket/port
         (only-in "guidance.rkt" weak-match weak-match-path weak-match-polarity
                  weak-match-matched? weak-match-start-token weak-match-end-token))
(require/typed "weak-json.rkt"
  [read-json-file (-> Path-String Any)]
  [write-json-file (-> Any Path-String Void)])

(provide WeakSchema WeakObservation WeakModel
         (struct-out token-span)
         make-weak-schema weak-schema-fingerprint weak-schema-shape-fingerprint
         weak-schema-tokenizer-fingerprint
         weak-observation? weak-observation-labels weak-observation-rule-paths
         weak-observation-polarities weak-observation-scope-spans
         weak-observation-schema-fingerprint weak-observation-spec-fingerprint
         weak-model? weak-model-fingerprint weak-model-schema-fingerprint
         weak-model-diagnostics
         fingerprint-datum make-weak-observation
         fit-weak-model weak-posterior save-weak-model load-weak-model)

(define-type Label Integer)
(define-type TokenIds (Listof Natural))

(struct token-span
  ([start-token : Natural] [end-token : Natural])
  #:transparent)

(struct weak-schema
  ([paths : (Vectorof String)]
   [polarities : (Vectorof Symbol)]
   [kinds : (Vectorof Symbol)]
   [tokenizer-fingerprint : String]
   [shape-fingerprint : String]
   [fingerprint : String])
  #:transparent)
(define-type WeakSchema weak-schema)

(struct weak-observation
  ([labels : (Vectorof Label)]
   [schema : WeakSchema]
   [spec-fingerprint : String]
   [spans : (Option (Vectorof (Listof token-span)))]
   [token-ids : (Option TokenIds)])
  #:transparent)
(define-type WeakObservation weak-observation)

(: weak-observation-rule-paths (-> WeakObservation (Vectorof String)))
(define (weak-observation-rule-paths observation)
  (weak-schema-paths (weak-observation-schema observation)))
(: weak-observation-polarities (-> WeakObservation (Vectorof Symbol)))
(define (weak-observation-polarities observation)
  (weak-schema-polarities (weak-observation-schema observation)))
(: weak-observation-scope-spans (-> WeakObservation (Option (Vectorof (Listof token-span)))))
(define (weak-observation-scope-spans observation) (weak-observation-spans observation))
(: weak-observation-schema-fingerprint (-> WeakObservation String))
(define (weak-observation-schema-fingerprint observation)
  (weak-schema-fingerprint (weak-observation-schema observation)))

(struct weak-model
  ([schema : WeakSchema]
   [prior-good : Real]
   [p-fire-bad : (Vectorof Real)]
   [p-fire-good : (Vectorof Real)]
   [fingerprint : String]
   [diagnostics : (Immutable-HashTable Symbol Any)])
  #:transparent)
(define-type WeakModel weak-model)

(: weak-model-schema-fingerprint (-> WeakModel String))
(define (weak-model-schema-fingerprint model)
  (weak-schema-fingerprint (weak-model-schema model)))

(: fingerprint-datum (-> Any String))
(define (fingerprint-datum datum)
  (apply string-append
         (for/list : (Listof String)
                   ([byte (in-bytes
                           (sha256-bytes
                            (open-input-bytes
                             (call-with-output-bytes
                              (lambda ([out : Output-Port]) (write datum out))))))])
           (define hex (number->string byte 16))
           (if (= (string-length hex) 1) (string-append "0" hex) hex))))

(: descriptor-parts (-> Any (Values String Symbol Symbol)))
(define (descriptor-parts descriptor)
  (match descriptor
    [(list (? string? path) (? symbol? polarity) (? symbol? kind))
     (values path polarity kind)]
    [_ (raise-argument-error 'make-weak-observation
                             "(list path-string polarity-symbol matcher-kind-symbol)"
                             descriptor)]))

(: make-weak-schema (-> (Listof Any) String Any WeakSchema))
(define (make-weak-schema descriptors tokenizer-fingerprint shape-form)
  (define count (length descriptors))
  (define paths : (Vectorof String) (make-vector count ""))
  (define polarities : (Vectorof Symbol) (make-vector count 'prefer))
  (define kinds : (Vectorof Symbol) (make-vector count 'ere))
  (for ([descriptor (in-list descriptors)] [i : Natural (in-naturals)])
    (define-values (path polarity kind) (descriptor-parts descriptor))
    (vector-set! paths i path)
    (vector-set! polarities i polarity)
    (vector-set! kinds i kind))
  (define shape (fingerprint-datum (list 'rack-llm-shape 2 shape-form)))
  (define fp
    (fingerprint-datum
     (list 'rack-llm-weak-schema 3 'match-or-zero-accepting-parses-v2
           tokenizer-fingerprint shape descriptors)))
  (weak-schema (vector->immutable-vector paths)
               (vector->immutable-vector polarities)
               (vector->immutable-vector kinds)
               tokenizer-fingerprint shape fp))

(: make-weak-observation
   (->* (WeakSchema Any (Listof weak-match)) (#:trace? Boolean #:token-ids TokenIds)
        WeakObservation))
(define (make-weak-observation schema spec-form matches #:trace? [trace? #f] #:token-ids [ids '()])
  (define paths (weak-schema-paths schema))
  (define polarities (weak-schema-polarities schema))
  (define count (vector-length paths))
  (define labels : (Vectorof Label) (make-vector count 0))
  (define spans : (Vectorof (Listof token-span)) (make-vector count '()))
  (for ([path (in-vector paths)] [polarity (in-vector polarities)] [i : Natural (in-naturals)])
    (define occurrences
      (filter (lambda ([m : weak-match]) (string=? path (weak-match-path m))) matches))
    (when trace?
      (vector-set! spans i
                   (for/list : (Listof token-span) ([m (in-list occurrences)])
                     (token-span (weak-match-start-token m) (weak-match-end-token m)))))
    (when (ormap weak-match-matched? occurrences)
      (vector-set! labels i (if (eq? polarity 'prefer) 1 -1))))
  (weak-observation (vector->immutable-vector labels)
                    schema
                    (fingerprint-datum (list 'rack-llm-spec 3 spec-form))
                    (and trace? (vector->immutable-vector spans))
                    (and trace? ids)))

(: clamp-prob (-> Real Real))
(define (clamp-prob x) (max 1e-12 (min (- 1.0 1e-12) x)))

(: logit (-> Real Real))
(define (logit p*)
  (define p (clamp-prob p*))
  (assert (log (/ p (- 1.0 p))) real?))

(: logistic (-> Real Real))
(define (logistic x)
  (if (>= x 0.0)
      (/ 1.0 (+ 1.0 (exp (- x))))
      (let ([e (exp x)]) (/ e (+ 1.0 e)))))

(: real-log (-> Real Real))
(define (real-log x) (assert (log x) real?))

(: finite-prob? (-> Any Boolean))
(define (finite-prob? x)
  (and (real? x) (finite-prob-real? x)))

(: finite-prob-real? (-> Real Boolean))
(define (finite-prob-real? x)
  (and (= x x) (> x 0.0) (< x 1.0)
       (not (eqv? x +inf.0)) (not (eqv? x -inf.0))))

(: observation-fires (-> WeakObservation (Vectorof Boolean)))
(define (observation-fires observation)
  (for/vector : (Vectorof Boolean) ([label (in-vector (weak-observation-labels observation))])
    (not (zero? label))))

(: same-column? (-> (Listof (Vectorof Boolean)) Natural Natural Boolean))
(define (same-column? rows left right)
  (for/and : Boolean ([row (in-list rows)])
    (eq? (vector-ref row left) (vector-ref row right))))

(: corpus-diagnostics
   (-> (Listof (Vectorof Boolean)) (Vectorof String) (Immutable-HashTable Symbol Any)))
(define (corpus-diagnostics rows paths)
  (define n (length rows))
  (define m (vector-length paths))
  (define coverage
    (for/vector : (Vectorof Real) ([i (in-range m)])
      (/ (for/sum : Natural ([row (in-list rows)]) (if (vector-ref row i) 1 0)) n)))
  (define pairs
    (for*/list : (Listof Any) ([i (in-range m)] [j (in-range (add1 i) m)])
      (define-values (n11 n10 n01 n00)
        (for/fold ([n11 : Natural 0] [n10 : Natural 0]
                   [n01 : Natural 0] [n00 : Natural 0]) ([row (in-list rows)])
          (case (+ (if (vector-ref row i) 2 0) (if (vector-ref row j) 1 0))
            [(3) (values (add1 n11) n10 n01 n00)]
            [(2) (values n11 (add1 n10) n01 n00)]
            [(1) (values n11 n10 (add1 n01) n00)]
            [else (values n11 n10 n01 (add1 n00))])))
      (define union (+ n11 n10 n01))
      (define denominator
        (sqrt (* (+ n11 n10) (+ n01 n00) (+ n11 n01) (+ n10 n00))))
      (define phi (and (> denominator 0.0)
                       (/ (- (* n11 n00) (* n10 n01)) denominator)))
      (hash 'left (vector-ref paths i) 'right (vector-ref paths j)
            'agreement (/ (+ n11 n00) n)
            'jaccard (and (> union 0) (/ n11 union))
            'phi phi
            'warning (and phi (>= (abs phi) 0.9)))))
  ;; Participation ratio of the centered fire covariance eigenvalues.
  (define covariance
    (for/vector : (Vectorof (Vectorof Real)) ([i (in-range m)])
      (for/vector : (Vectorof Real) ([j (in-range m)])
        (/ (for/sum : Real ([row (in-list rows)])
             (* (- (if (vector-ref row i) 1.0 0.0) (vector-ref coverage i))
                (- (if (vector-ref row j) 1.0 0.0) (vector-ref coverage j))))
           n))))
  (define trace (for/sum : Real ([i (in-range m)]) (vector-ref (vector-ref covariance i) i)))
  (define frobenius2
    (for*/sum : Real ([row (in-vector covariance)] [x (in-vector row)]) (* x x)))
  (hash 'coverage (vector->list coverage)
        'pairs pairs
        'high-correlation-warnings
        (count (lambda ([pair : Any]) (and (hash? pair) (hash-ref pair 'warning #f))) pairs)
        'effective-rank (if (zero? frobenius2) 0.0 (/ (* trace trace) frobenius2))))

(: objective (-> (Listof (Vectorof Boolean)) Real (Vectorof Real) (Vectorof Real) Real))
(define (objective rows prior bad good)
  (for/sum : Real ([row (in-list rows)])
    (define l0
      (+ (real-log (- 1.0 prior))
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector bad)])
           (real-log (if fire? p (- 1.0 p))))))
    (define l1
      (+ (real-log prior)
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector good)])
           (real-log (if fire? p (- 1.0 p))))))
    (define top (max l0 l1))
    (+ top (real-log (+ (exp (- l0 top)) (exp (- l1 top)))))))

(: responsibilities
   (-> (Listof (Vectorof Boolean)) Real (Vectorof Real) (Vectorof Real) (Vectorof Real)))
(define (responsibilities rows prior bad good)
  (for/vector : (Vectorof Real) ([row (in-list rows)])
    (define l0
      (+ (real-log (- 1.0 prior))
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector bad)])
           (real-log (if fire? p (- 1.0 p))))))
    (define l1
      (+ (real-log prior)
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector good)])
           (real-log (if fire? p (- 1.0 p))))))
    (logistic (- l1 l0))))

(struct fit-result
  ([prior : Real] [bad : (Vectorof Real)] [good : (Vectorof Real)]
   [objective : Real] [iterations : Natural] [converged? : Boolean])
  #:transparent)

(: one-fit
   (-> (Listof (Vectorof Boolean)) (Vectorof Symbol) Natural Real Real Real
       Pseudo-Random-Generator fit-result))
(define (one-fit rows polarities max-iterations tolerance pseudocount separation rng)
  (define n (length rows))
  (define m (vector-length polarities))
  (define coverages
    (for/vector : (Vectorof Real) ([i (in-range m)])
      (/ (for/sum : Natural ([row (in-list rows)]) (if (vector-ref row i) 1 0)) n)))
  (define prior : Real
    (parameterize ([current-pseudo-random-generator rng])
      (logistic (* 0.25 (- (* 2.0 (random)) 1.0)))))
  (define bad : (Vectorof Real) (make-vector m 0.5))
  (define good : (Vectorof Real) (make-vector m 0.5))
  (for ([coverage (in-vector coverages)] [polarity (in-vector polarities)] [i : Natural (in-naturals)])
    (define jitter
      (parameterize ([current-pseudo-random-generator rng])
        (* 0.25 (- (* 2.0 (random)) 1.0))))
    (define direction (if (eq? polarity 'prefer) 1.0 -1.0))
    (vector-set! good i (clamp-prob (logistic (+ (logit coverage) (* direction separation) jitter))))
    (vector-set! bad i (clamp-prob (logistic (- (logit coverage) (* direction separation) jitter)))))
  (let loop ([iteration : Natural 0]
             [prior : Real prior]
             [bad : (Vectorof Real) bad]
             [good : (Vectorof Real) good]
             [previous : Real -inf.0])
    (define score (objective rows prior bad good))
    (define relative (/ (abs (- score previous)) (max 1.0 (abs previous))))
    (cond
      [(and (> iteration 0) (<= relative tolerance))
       (fit-result prior bad good score iteration #t)]
      [(>= iteration max-iterations)
       (fit-result prior bad good score iteration #f)]
      [(< score (- previous 1e-8))
       (fit-result prior bad good score iteration #f)]
      [else
       (define r (responsibilities rows prior bad good))
       (define good-total (for/sum : Real ([x (in-vector r)]) x))
       (define bad-total (- n good-total))
       (define next-prior (clamp-prob (/ (+ good-total pseudocount)
                                         (+ n (* 2.0 pseudocount)))))
       (define next-bad : (Vectorof Real) (make-vector m 0.5))
       (define next-good : (Vectorof Real) (make-vector m 0.5))
       (for ([i (in-range m)] [polarity (in-vector polarities)])
         (define good-fire
           (for/sum : Real ([row (in-list rows)] [weight (in-vector r)])
             (if (vector-ref row i) weight 0.0)))
         (define bad-fire
           (for/sum : Real ([row (in-list rows)] [weight (in-vector r)])
             (if (vector-ref row i) (- 1.0 weight) 0.0)))
         (define gb (clamp-prob (/ (+ bad-fire pseudocount)
                                   (+ bad-total (* 2.0 pseudocount)))))
         (define gg (clamp-prob (/ (+ good-fire pseudocount)
                                   (+ good-total (* 2.0 pseudocount)))))
         (define violates?
           (if (eq? polarity 'prefer) (< gg gb) (> gg gb)))
         (if violates?
             (let ([pooled (clamp-prob
                            (/ (+ good-fire bad-fire (* 2.0 pseudocount))
                               (+ n (* 4.0 pseudocount))))])
               (vector-set! next-bad i pooled)
               (vector-set! next-good i pooled))
             (begin (vector-set! next-bad i gb) (vector-set! next-good i gg))))
       (loop (add1 iteration) next-prior next-bad next-good score)])))

(: fit-weak-model
   (->* ((Listof WeakObservation))
        (#:max-iterations Positive-Integer #:tolerance Real #:pseudocount Real
         #:restarts Positive-Integer #:seed Integer)
        WeakModel))
(define (fit-weak-model observations
                        #:max-iterations [max-iterations 200]
                        #:tolerance [tolerance 1e-7]
                        #:pseudocount [pseudocount 1.0]
                        #:restarts [restarts 8]
                        #:seed [seed 0])
  (when (null? observations)
    (raise-argument-error 'fit-weak-model "non-empty observations" observations))
  (unless (and (> tolerance 0.0) (> pseudocount 0.0))
    (raise-arguments-error 'fit-weak-model "tolerance and pseudocount must be positive"))
  (define first (car observations))
  (define schema (weak-observation-schema-fingerprint first))
  (define schema* (weak-observation-schema first))
  (define paths (weak-schema-paths schema*))
  (define polarities (weak-schema-polarities schema*))
  (define m (vector-length paths))
  (when (zero? m) (error 'fit-weak-model "weak schema has no prefer/avoid rules"))
  (for ([observation (in-list observations)])
    (unless (and (string=? schema (weak-observation-schema-fingerprint observation))
                 (= m (vector-length (weak-observation-labels observation))))
      (error 'fit-weak-model "incompatible weak-observation schema")))
  (define rows (map observation-fires observations))
  (define informative
    (for/list : (Listof Natural) ([i : Natural (in-range m)]
                                  #:when (let ([fires (count (lambda ([row : (Vectorof Boolean)])
                                                              (vector-ref row i)) rows)])
                                           (and (> fires 0) (< fires (length rows)))))
      i))
  (when (< (length informative) 3)
    (error 'fit-weak-model "unidentifiable weak model: fewer than three informative rules"))
  (for* ([left (in-list informative)] [right (in-list informative)] #:when (< left right))
    (when (same-column? rows left right)
      (error 'fit-weak-model "unidentifiable weak model: duplicate rule columns ~a and ~a"
             (vector-ref paths left) (vector-ref paths right))))
  (define fits
    (for/list : (Listof fit-result) ([restart : Natural (in-range restarts)])
      (define rng (make-pseudo-random-generator))
      (parameterize ([current-pseudo-random-generator rng])
        (random-seed (add1 (abs (+ seed restart)))))
      (one-fit rows polarities max-iterations tolerance pseudocount
               (+ 0.75 (* 0.05 restart)) rng)))
  (define converged (filter fit-result-converged? fits))
  (when (null? converged) (error 'fit-weak-model "no EM restart converged"))
  (define best (argmax fit-result-objective converged))
  (define active
    (for/sum : Natural ([b (in-vector (fit-result-bad best))]
                        [g (in-vector (fit-result-good best))])
      (if (>= (abs (- g b)) 1e-3) 1 0)))
  (when (< active 3)
    (error 'fit-weak-model "unidentifiable weak model: fitted solution collapsed"))
  (define model-form
    (list 'rack-llm-weak-model 3 schema (fit-result-prior best)
          (vector->list (fit-result-bad best)) (vector->list (fit-result-good best))))
  (define diagnostics
    (for/fold ([d : (Immutable-HashTable Symbol Any) (corpus-diagnostics rows paths)])
              ([entry (in-list
                       (list (cons 'iterations (fit-result-iterations best))
                             (cons 'objective (fit-result-objective best))
                             (cons 'observations (length observations))
                             (cons 'rules m)
                             (cons 'active-rules active)))])
      (hash-set d (car entry) (cdr entry))))
  (weak-model schema* (fit-result-prior best)
              (vector->immutable-vector (fit-result-bad best))
              (vector->immutable-vector (fit-result-good best))
              (fingerprint-datum model-form)
              diagnostics))

(: weak-posterior (-> WeakModel WeakObservation Real))
(define (weak-posterior model observation)
  (unless (string=? (weak-model-schema-fingerprint model)
                    (weak-observation-schema-fingerprint observation))
    (error 'weak-posterior "incompatible weak-model and observation schemas"))
  (define fires (observation-fires observation))
  (define prior (weak-model-prior-good model))
  (define log-odds
    (+ (logit prior)
       (for/sum : Real ([fire? (in-vector fires)]
                        [bad (in-vector (weak-model-p-fire-bad model))]
                        [good (in-vector (weak-model-p-fire-good model))])
         (if fire?
             (real-log (/ good bad))
             (real-log (/ (- 1.0 good) (- 1.0 bad)))))))
  (logistic log-odds))

(: model->jsexpr (-> WeakModel Any))
(define (model->jsexpr model)
  (define schema (weak-model-schema model))
  (hash 'format "rack-llm-weak-model"
        'version 3
        'model "independent-polarity-bernoulli"
        'observation_semantics "match-or-zero-accepting-parses-v2"
        'schema_fingerprint (weak-model-schema-fingerprint model)
        'fingerprint (weak-model-fingerprint model)
        'tokenizer_fingerprint (weak-schema-tokenizer-fingerprint schema)
        'shape_fingerprint (weak-schema-shape-fingerprint schema)
        'paths (vector->list (weak-schema-paths schema))
        'polarities (map symbol->string (vector->list (weak-schema-polarities schema)))
        'kinds (map symbol->string (vector->list (weak-schema-kinds schema)))
        'prior_good (weak-model-prior-good model)
        'p_fire_bad (vector->list (weak-model-p-fire-bad model))
        'p_fire_good (vector->list (weak-model-p-fire-good model))
        'diagnostics (json-safe (weak-model-diagnostics model))))

(: json-safe (-> Any Any))
(define (json-safe value)
  (cond
    [(and (real? value) (exact? value)) (exact->inexact value)]
    [(hash? value)
     (for/hash ([(key item) (in-hash value)])
       (values key (json-safe item)))]
    [(list? value) (map json-safe value)]
    [(vector? value) (map json-safe (vector->list value))]
    [else value]))

(: save-weak-model (-> WeakModel Path-String Void))
(define (save-weak-model model path)
  (write-json-file (model->jsexpr model) path))

(: list->real-vector (-> Symbol Any (Vectorof Real)))
(define (list->real-vector who value)
  (unless (and (list? value) (andmap finite-prob? value))
    (raise-argument-error who "list of finite probabilities strictly between zero and one" value))
  (list->vector (map (lambda ([x : Any]) (assert x real?)) (assert value list?))))

(: load-weak-model (-> Path-String WeakModel))
(define (load-weak-model path)
  (define payload (read-json-file path))
  (unless (hash? payload) (error 'load-weak-model "model file is not a JSON object"))
  (define table (assert payload hash?))
  (define (field [key : Symbol]) (hash-ref table key (lambda () (error 'load-weak-model "missing ~a" key))))
  (unless (and (equal? (field 'format) "rack-llm-weak-model")
               (equal? (field 'version) 3)
               (equal? (field 'model) "independent-polarity-bernoulli")
               (equal? (field 'observation_semantics)
                       "match-or-zero-accepting-parses-v2"))
    (error 'load-weak-model "unsupported weak-model format or version"))
  (define paths-list (field 'paths))
  (define polarities-list (field 'polarities))
  (define kinds-list (field 'kinds))
  (unless (and (list? paths-list) (andmap string? paths-list)
               (list? polarities-list) (andmap string? polarities-list)
               (list? kinds-list) (andmap string? kinds-list))
    (error 'load-weak-model "invalid weak schema arrays"))
  (define paths (list->vector (filter string? (assert paths-list list?))))
  (define polarities
    (list->vector (map string->symbol (filter string? (assert polarities-list list?)))))
  (define kinds (list->vector (map string->symbol (filter string? (assert kinds-list list?)))))
  (define bad (list->real-vector 'load-weak-model (field 'p_fire_bad)))
  (define good (list->real-vector 'load-weak-model (field 'p_fire_good)))
  (define prior (field 'prior_good))
  (unless (and (finite-prob? prior)
               (= (vector-length paths) (vector-length polarities)
                  (vector-length kinds) (vector-length bad) (vector-length good)))
    (error 'load-weak-model "inconsistent weak-model dimensions"))
  (for ([polarity (in-vector polarities)] [b (in-vector bad)] [g (in-vector good)])
    (unless (or (and (eq? polarity 'prefer) (>= g b))
                (and (eq? polarity 'avoid) (<= g b)))
      (error 'load-weak-model "weak-model violates polarity constraints")))
  (define schema-fp (assert (field 'schema_fingerprint) string?))
  (define tokenizer-fp (assert (field 'tokenizer_fingerprint) string?))
  (define shape-fp (assert (field 'shape_fingerprint) string?))
  (define descriptors
    (for/list : (Listof Any) ([p (in-vector paths)] [polarity (in-vector polarities)]
                              [kind (in-vector kinds)])
      (list p polarity kind)))
  (define computed-schema
    (fingerprint-datum
     (list 'rack-llm-weak-schema 3 'match-or-zero-accepting-parses-v2
           tokenizer-fp shape-fp descriptors)))
  (unless (string=? computed-schema schema-fp)
    (error 'load-weak-model "weak schema fingerprint mismatch"))
  (define schema* (weak-schema (vector->immutable-vector paths)
                               (vector->immutable-vector polarities)
                               (vector->immutable-vector kinds)
                               tokenizer-fp shape-fp schema-fp))
  (define form (list 'rack-llm-weak-model 3 schema-fp prior
                     (vector->list bad) (vector->list good)))
  (define fingerprint (fingerprint-datum form))
  (unless (string=? fingerprint (assert (field 'fingerprint) string?))
    (error 'load-weak-model "weak-model fingerprint mismatch"))
  (define raw-diagnostics (field 'diagnostics))
  (define diagnostics : (Immutable-HashTable Symbol Any)
    (if (hash? raw-diagnostics)
        (for/hash : (Immutable-HashTable Symbol Any)
                  ([(key value) (in-hash raw-diagnostics)] #:when (symbol? key))
          (values key value))
        (hash)))
  (weak-model schema* (assert prior real?)
              (vector->immutable-vector bad) (vector->immutable-vector good)
              fingerprint
              (hash-set diagnostics 'loaded-from
                        (path->string (path->complete-path path)))))
