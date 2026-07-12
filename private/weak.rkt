#lang typed/racket/base/no-check

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         (only-in "guidance.rkt" weak-match weak-match-path weak-match-polarity
                  weak-match-matched? weak-match-start-token weak-match-end-token
                  weak-match-token-ids))

(provide WeakObservation WeakModel
         (struct-out token-span)
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
  ([start-token : Natural] [end-token : Natural] [token-ids : TokenIds])
  #:transparent)

(struct weak-observation
  ([labels : (Vectorof Label)]
   [paths : (Vectorof String)]
   [polarities : (Vectorof Symbol)]
   [kinds : (Vectorof Symbol)]
   [spans : (Vectorof (Listof token-span))]
   [schema-fingerprint : String]
   [spec-fingerprint : String])
  #:transparent)
(define-type WeakObservation weak-observation)

(: weak-observation-rule-paths (-> WeakObservation (Vectorof String)))
(define (weak-observation-rule-paths observation) (weak-observation-paths observation))
(: weak-observation-scope-spans (-> WeakObservation (Vectorof (Listof token-span))))
(define (weak-observation-scope-spans observation) (weak-observation-spans observation))

(struct weak-model
  ([paths : (Vectorof String)]
   [polarities : (Vectorof Symbol)]
   [kinds : (Vectorof Symbol)]
   [schema-fingerprint : String]
   [prior-good : Real]
   [p-fire-bad : (Vectorof Real)]
   [p-fire-good : (Vectorof Real)]
   [fingerprint : String]
   [diagnostics : (Immutable-HashTable Symbol Any)])
  #:transparent)
(define-type WeakModel weak-model)

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

(: schema-fingerprint (-> (Listof Any) String))
(define (schema-fingerprint descriptors)
  (fingerprint-datum (list 'rack-llm-weak-schema 1 'match-or-zero-v1 descriptors)))

(: make-weak-observation (-> (Listof Any) Any (Listof weak-match) WeakObservation))
(define (make-weak-observation descriptors spec-form matches)
  (define count (length descriptors))
  (define labels : (Vectorof Label) (make-vector count 0))
  (define paths : (Vectorof String) (make-vector count ""))
  (define polarities : (Vectorof Symbol) (make-vector count 'prefer))
  (define kinds : (Vectorof Symbol) (make-vector count 'ere))
  (define spans : (Vectorof (Listof token-span)) (make-vector count '()))
  (for ([descriptor (in-list descriptors)] [i : Natural (in-naturals)])
    (define-values (path polarity kind) (descriptor-parts descriptor))
    (vector-set! paths i path)
    (vector-set! polarities i polarity)
    (vector-set! kinds i kind)
    (define occurrences
      (filter (lambda ([m : weak-match]) (string=? path (weak-match-path m))) matches))
    (vector-set! spans i
                 (for/list : (Listof token-span) ([m (in-list occurrences)])
                   (token-span (weak-match-start-token m) (weak-match-end-token m)
                               (weak-match-token-ids m))))
    (when (ormap weak-match-matched? occurrences)
      (vector-set! labels i (if (eq? polarity 'prefer) 1 -1))))
  (weak-observation (vector->immutable-vector labels)
                    (vector->immutable-vector paths)
                    (vector->immutable-vector polarities)
                    (vector->immutable-vector kinds)
                    (vector->immutable-vector spans)
                    (schema-fingerprint descriptors)
                    (fingerprint-datum (list 'rack-llm-spec 1 spec-form))))

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

(: finite-prob? (-> Any Boolean : Real))
(define (finite-prob? x)
  (and (real? x) (= x x) (> x 0.0) (< x 1.0)
       (not (eqv? x +inf.0)) (not (eqv? x -inf.0))))

(: observation-fires (-> WeakObservation (Vectorof Boolean)))
(define (observation-fires observation)
  (for/vector : (Vectorof Boolean) ([label (in-vector (weak-observation-labels observation))])
    (not (zero? label))))

(: same-column? (-> (Listof (Vectorof Boolean)) Natural Natural Boolean))
(define (same-column? rows left right)
  (for/and : Boolean ([row (in-list rows)])
    (eq? (vector-ref row left) (vector-ref row right))))

(: objective (-> (Listof (Vectorof Boolean)) Real (Vectorof Real) (Vectorof Real) Real))
(define (objective rows prior bad good)
  (for/sum : Real ([row (in-list rows)])
    (define l0
      (+ (log (- 1.0 prior))
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector bad)])
           (log (if fire? p (- 1.0 p))))))
    (define l1
      (+ (log prior)
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector good)])
           (log (if fire? p (- 1.0 p))))))
    (define top (max l0 l1))
    (+ top (log (+ (exp (- l0 top)) (exp (- l1 top)))))))

(: responsibilities
   (-> (Listof (Vectorof Boolean)) Real (Vectorof Real) (Vectorof Real) (Vectorof Real)))
(define (responsibilities rows prior bad good)
  (for/vector : (Vectorof Real) ([row (in-list rows)])
    (define l0
      (+ (log (- 1.0 prior))
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector bad)])
           (log (if fire? p (- 1.0 p))))))
    (define l1
      (+ (log prior)
         (for/sum : Real ([fire? (in-vector row)] [p (in-vector good)])
           (log (if fire? p (- 1.0 p))))))
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
  (define paths (weak-observation-paths first))
  (define polarities (weak-observation-polarities first))
  (define m (vector-length paths))
  (when (zero? m) (error 'fit-weak-model "weak schema has no prefer/avoid rules"))
  (for ([observation (in-list observations)])
    (unless (and (string=? schema (weak-observation-schema-fingerprint observation))
                 (= m (vector-length (weak-observation-labels observation))))
      (error 'fit-weak-model "incompatible weak-observation schema")))
  (define rows (map observation-fires observations))
  (define informative
    (for/list : (Listof Natural) ([i (in-range m)]
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
    (for/list : (Listof fit-result) ([restart (in-range restarts)])
      (define rng (make-pseudo-random-generator))
      (parameterize ([current-pseudo-random-generator rng])
        (random-seed (+ seed restart)))
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
  (define kinds (weak-observation-kinds first))
  (define descriptors
    (for/list : (Listof Any) ([path (in-vector paths)] [polarity (in-vector polarities)]
                              [kind (in-vector kinds)])
      (list path polarity kind)))
  (define model-form
    (list 'rack-llm-weak-model 1 schema (fit-result-prior best)
          (vector->list (fit-result-bad best)) (vector->list (fit-result-good best))))
  (weak-model paths polarities kinds schema (fit-result-prior best)
              (vector->immutable-vector (fit-result-bad best))
              (vector->immutable-vector (fit-result-good best))
              (fingerprint-datum model-form)
              (hash 'iterations (fit-result-iterations best)
                    'objective (fit-result-objective best)
                    'observations (length observations)
                    'rules m
                    'active-rules active)))

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
             (log (/ good bad))
             (log (/ (- 1.0 good) (- 1.0 bad)))))))
  (logistic log-odds))

(: model->jsexpr (-> WeakModel Any))
(define (model->jsexpr model)
  (hash 'format "rack-llm-weak-model"
        'version 1
        'model "independent-polarity-bernoulli"
        'observation_semantics "match-or-zero-v1"
        'schema_fingerprint (weak-model-schema-fingerprint model)
        'fingerprint (weak-model-fingerprint model)
        'paths (vector->list (weak-model-paths model))
        'polarities (map symbol->string (vector->list (weak-model-polarities model)))
        'kinds (map symbol->string (vector->list (weak-model-kinds model)))
        'prior_good (weak-model-prior-good model)
        'p_fire_bad (vector->list (weak-model-p-fire-bad model))
        'p_fire_good (vector->list (weak-model-p-fire-good model))
        'diagnostics (weak-model-diagnostics model)))

(: save-weak-model (-> WeakModel Path-String Void))
(define (save-weak-model model path)
  (define target (path->complete-path path))
  (define parent (or (path-only target) (current-directory)))
  (make-directory* parent)
  (define temporary (make-temporary-file "weak-model-~a.json" #f parent))
  (with-handlers ([exn:fail? (lambda ([exn : exn:fail])
                               (when (file-exists? temporary) (delete-file temporary))
                               (raise exn))])
    (call-with-output-file temporary
      (lambda ([out : Output-Port]) (write-json (model->jsexpr model) out) (newline out))
      #:exists 'truncate/replace)
    (rename-file-or-directory temporary target #t)))

(: list->real-vector (-> Symbol Any (Vectorof Real)))
(define (list->real-vector who value)
  (unless (and (list? value) (andmap finite-prob? value))
    (raise-argument-error who "list of finite probabilities strictly between zero and one" value))
  (list->vector (map (lambda ([x : Any]) (assert x finite-prob?)) (assert value list?))))

(: load-weak-model (-> Path-String WeakModel))
(define (load-weak-model path)
  (define payload (call-with-input-file path read-json))
  (unless (hash? payload) (error 'load-weak-model "model file is not a JSON object"))
  (define table (assert payload hash?))
  (define (field [key : Symbol]) (hash-ref table key (lambda () (error 'load-weak-model "missing ~a" key))))
  (unless (and (equal? (field 'format) "rack-llm-weak-model")
               (equal? (field 'version) 1)
               (equal? (field 'model) "independent-polarity-bernoulli")
               (equal? (field 'observation_semantics) "match-or-zero-v1"))
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
  (define schema (assert (field 'schema_fingerprint) string?))
  (define form (list 'rack-llm-weak-model 1 schema prior (vector->list bad) (vector->list good)))
  (define fingerprint (fingerprint-datum form))
  (unless (string=? fingerprint (assert (field 'fingerprint) string?))
    (error 'load-weak-model "weak-model fingerprint mismatch"))
  (weak-model (vector->immutable-vector paths)
              (vector->immutable-vector polarities)
              (vector->immutable-vector kinds)
              schema (assert prior real?)
              (vector->immutable-vector bad) (vector->immutable-vector good)
              fingerprint (hash 'loaded-from (path->string (path->complete-path path)))))
