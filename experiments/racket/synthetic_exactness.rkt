#lang racket/base

(require json
         racket/cmdline
         racket/file
         racket/list
         racket/path
         racket/random
         racket/string
         rack-llm
         rack-llm/backend)

(define output-path (make-parameter "experiments/artifacts/hard/synthetic_raw.jsonl"))
(define samples-per-seed (make-parameter 20000))
(define seeds (make-parameter '(0 1 2 3 4)))

(command-line
 #:once-each
 [("--output") value "Output JSONL" (output-path value)]
 [("--samples-per-seed") value "Samples per seed"
                         (samples-per-seed (string->number value))]
 [("--seeds") value "Comma-separated seeds"
              (seeds (map string->number (string-split value ",")))])

;; Q_T emits content until the first EOG, or exactly T content tokens when the
;; horizon is reached.  EOG is not part of the returned token sequence.
(define vocab (vector " a" " b" " c" " d" "<eog>"))
(define probabilities #(0.4 0.3 0.15 0.05 0.1))
(define eog-id 4)
(define accepted-texts '(" a c" " a b c"))

(define tok
  (make-tokenizer
   #:vocab-size 5
   #:fingerprint "synthetic-finite-v1"
   #:token-ref (lambda (id) (vector-ref vocab id))
   #:tokenize
   (lambda (source)
     (cond
       [(string=? source "") '()]
       [else
        (let loop ([remaining source] [ids '()])
          (if (string=? remaining "")
              (reverse ids)
              (let ([match
                     (for/first ([piece (in-vector vocab)] [id (in-naturals)]
                                 #:when (string-prefix? remaining piece))
                       (cons id piece))])
                (unless match (error 'tokenize "unknown text ~s" remaining))
                (loop (substring remaining (string-length (cdr match)))
                      (cons (car match) ids)))))]))
   #:detokenize
   (lambda (ids)
     (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))))

(define (tempered-probabilities temperature)
  (define weights
    (for/vector ([probability (in-vector probabilities)])
      (expt probability (/ 1.0 temperature))))
  (define total (for/sum ([weight (in-vector weights)]) weight))
  (for/vector ([weight (in-vector weights)]) (/ weight total)))

;; A deliberately tiny public backend.  It implements the same factor contract
;; as a model backend, while the finite token distribution remains enumerable.
(define provider*
  (make-provider
   #:vocab-size 5 #:eog-token-ids (list eog-id) #:cohort-width 8
   #:open-cohort (lambda (prompts) prompts)
   #:restore-lanes! (lambda (_cohort _lanes) (void))
   #:sample-factors
   (lambda (_cohort entries)
     (for/list ([entry (in-list entries)])
       (define request (cdr entry))
       (define base (tempered-probabilities (factor-request-temperature request)))
       (define domain (factor-request-domain request))
       (define children (make-hash (factor-request-children request)))
       (define (eligible? id)
         (and (or (not (factor-request-constrain? request))
                  (domain-member? domain id))
              (> (hash-ref children id 1.0) 0.0)))
       (define weights
         (for/vector ([probability (in-vector base)] [id (in-naturals)])
           (if (eligible? id) (* probability (hash-ref children id 1.0)) 0.0)))
       (define total (for/sum ([weight (in-vector weights)]) weight))
       (unless (> total 0.0) (error 'finite-backend "empty factor envelope"))
       (define target (* total (factor-request-draw request)))
       (define selected
         (let loop ([id 0] [accumulator 0.0])
           (define next (+ accumulator (vector-ref weights id)))
           (if (or (< target next) (= id (sub1 (vector-length weights))))
               id
               (loop (add1 id) next))))
       (define frontier
         (for/sum ([probability (in-vector base)] [id (in-naturals)]
                   #:when (domain-member? domain id))
           probability))
       (factor-selection selected (log (vector-ref base selected))
                         (vector-ref base selected) frontier)))
   #:decode! (lambda (_cohort _tokens) (void))
   #:close-cohort! (lambda (_cohort _poisoned?) (void))))
(define model* (make-backend tok provider* void))
(define program
  (seq (choice (lit " a") (seq (lit " a") (lit " b"))) (lit " c")))
(define compiled (compile-spec model* program))

(define (ids->text ids)
  (apply string-append (map (lambda (id) (vector-ref vocab id)) ids)))

(define (hard-valid? ids)
  (member (ids->text ids) accepted-texts))

;; Exhaustively enumerate the finite EOG-or-horizon process, then condition on
;; hard acceptance.  This deliberately replaces the old hand-written oracle.
(define (exact-conditioned horizon)
  (define masses (make-hash))
  (define (finish ids mass)
    (when (hard-valid? ids)
      (hash-update! masses (string->symbol (ids->text ids))
                    (lambda (old) (+ old mass)) 0.0)))
  (define (walk ids mass)
    (if (= (length ids) horizon)
        (finish ids mass)
        (for ([id (in-range (vector-length probabilities))])
          (define next-mass (* mass (vector-ref probabilities id)))
          (if (= id eog-id)
              (finish ids next-mass)
              (walk (append ids (list id)) next-mass)))))
  (walk '() 1.0)
  (define normalizer (for/sum ([mass (in-hash-values masses)]) mass))
  (for/hash ([(key mass) (in-hash masses)])
    (values key (/ mass normalizer))))

(define (weighted-id rng)
  (define draw (parameterize ([current-pseudo-random-generator rng]) (random)))
  (let loop ([index 0] [total 0.0])
    (define next (+ total (vector-ref probabilities index)))
    (if (or (< draw next) (= index (sub1 (vector-length probabilities))))
        index
        (loop (add1 index) next))))

(define (unconditional-sample rng horizon)
  (let loop ([ids '()] [draws 0])
    (if (= (length ids) horizon)
        (values ids draws)
        (let ([id (weighted-id rng)])
          (if (= id eog-id)
              (values ids (add1 draws))
              (loop (append ids (list id)) (add1 draws)))))))

(define (naive-sample rng horizon)
  (let loop ([draws 0])
    (define-values (ids proposal-draws) (unconditional-sample rng horizon))
    (define total (+ draws proposal-draws))
    (if (hard-valid? ids)
        (values (ids->text ids) total)
        (loop total))))

(define cases '((boundary . 3) (slack . 4)))

(make-directory* (or (path-only (output-path)) "."))
(call-with-output-file (output-path)
  (lambda (out)
    (for* ([case+horizon (in-list cases)]
           [seed (in-list (seeds))])
      (define case-name (car case+horizon))
      (define horizon (cdr case+horizon))
      (define theoretical (exact-conditioned horizon))
      (define cars-results
        (generate-batch
         (for/list ([sample-index (in-range (samples-per-seed))])
           (generation-request
            compiled "" #:max-attempts 1000
            #:temperature 1.0 #:max-tokens horizon
            #:seed (+ seed (* 100000 sample-index))))))
      (define cars-counts
        (for/hash ([text (in-list accepted-texts)])
          (values (string->symbol text)
                  (count (lambda (result)
                           (string=? text (generation-result-text result)))
                         cars-results))))
      (define cars-draws
        (for/sum ([result (in-list cars-results)])
          (generation-result-model-draws result)))
      (define rng (make-pseudo-random-generator))
      (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
      (define naive-counts (make-hash '((| a c| . 0) (| a b c| . 0))))
      (define naive-draws 0)
      (for ([_i (in-range (samples-per-seed))])
        (define-values (text draws) (naive-sample rng horizon))
        (hash-update! naive-counts (string->symbol text) add1)
        (set! naive-draws (+ naive-draws draws)))
      (write-json
       (hash
        'case (symbol->string case-name) 'horizon horizon 'seed seed
        'samples (samples-per-seed) 'theoretical theoretical
        'cars_counts cars-counts 'naive_counts naive-counts
        'cars_model_draws cars-draws 'naive_model_draws naive-draws
        'cars_invalid
        (count (lambda (result) (not (eq? (generation-result-status result) 'found)))
               cars-results))
       out)
      (newline out)
      (flush-output out)))
  #:exists 'truncate/replace)
(backend-close! model*)
