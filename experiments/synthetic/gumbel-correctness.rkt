#lang racket/base

(require racket/list
         racket/stream
         racket/string
         rack-llm/grammar
         rack-llm/grammar/combinators
         rack-llm/grammar/json
         rack-llm/grammar/mask
         rack-llm/providers/mock-provider
         rack-llm/providers/provider-v2
         rack-llm/sampling/gumbel-stream
         rack-llm/sampling/sampler-stats)

(provide enumerate-language
         total-variation
         kl-divergence
         run-synthetic-correctness
         write-synthetic-csv)

(struct enum-node
  (text tokens state logprob depth provider-state traces)
  #:transparent)

(define (enumerate-language provider matcher max-depth)
  (define vocab (provider-vocab provider))
  (let loop ([frontier (list (enum-node ""
                                        '()
                                        (matcher-start matcher)
                                        0.0
                                        0
                                        (provider-initial-state provider)
                                        '()))]
             [accepted '()])
    (cond
      [(null? frontier) (reverse accepted)]
      [else
       (define node (car frontier))
       (define rest (cdr frontier))
       (define accepted*
         (if (matcher-accepting? (enum-node-state node))
             (cons (enum-node->candidate node) accepted)
             accepted))
       (define children
         (if (< (enum-node-depth node) max-depth)
             (enumeration-children provider matcher vocab node)
             '()))
       (loop (append rest children) accepted*)])))

(define (total-variation p q)
  (* 0.5
     (for/sum ([key (in-list (distribution-keys p q))])
       (abs (- (hash-ref p key 0.0) (hash-ref q key 0.0))))))

(define (kl-divergence p q)
  (for/sum ([(key p-value) (in-hash p)]
            #:when (> p-value 0.0))
    (* p-value
       (log (/ p-value (max 1e-300 (hash-ref q key 0.0)))))))

(define (run-synthetic-correctness #:seed [seed 42]
                                   #:runs [runs 100]
                                   #:max-depth [max-depth 4])
  (for/list ([case (in-list synthetic-cases)])
    (define name (first case))
    (define provider (second case))
    (define matcher (compile-matcher (third case)))
    (define exact-candidates (enumerate-language provider matcher max-depth))
    (define exact-dist (candidate-distribution exact-candidates))
    (define empirical-dist
      (empirical-top1-distribution provider matcher seed runs max-depth))
    (hash 'case name
          'runs runs
          'candidate_count (length exact-candidates)
          'duplicate_rate
          (duplicate-rate
           (stream->list
            (gumbel-stream provider
                           matcher
                           (gumbel-config max-depth
                                          (length exact-candidates)
                                          1000
                                          seed
                                          'binary-heap
                                          '(tokens))
                           '())))
          'tv (total-variation exact-dist empirical-dist)
          'kl (kl-divergence exact-dist empirical-dist)
          'order_agreement
          (order-agreement
           (explicit-gumbel-order exact-candidates seed)
           (map candidate-text
                (stream->list
                 (gumbel-stream provider
                                matcher
                                (gumbel-config max-depth
                                               (length exact-candidates)
                                               1000
                                               seed
                                               'binary-heap
                                               '(tokens))
                                '())))))))

(define (write-synthetic-csv out rows)
  (displayln "case,runs,candidate_count,duplicate_rate,tv,kl,order_agreement" out)
  (for ([row (in-list rows)])
    (displayln
     (string-join
      (map (lambda (key) (format "~a" (hash-ref row key)))
           '(case runs candidate_count duplicate_rate tv kl order_agreement))
      ",")
     out)))

(define (enumeration-children provider matcher vocab node)
  (define result
    ((provider-next-logits provider)
     '()
     (enum-node-text node)
     (enum-node-provider-state node)))
  (define logprobs
    (normalize-masked-logits
     (mask-logits
      (logits-result-logits result)
      (allowed-token-mask matcher (enum-node-state node) vocab))))
  (for/list ([i (in-range (vector-length logprobs))]
             #:when (> (vector-ref logprobs i) -1e300))
    (define token (vector-ref vocab i))
    (enum-node
     (string-append (enum-node-text node) token)
     (append (enum-node-tokens node) (list i))
     (matcher-advance matcher (enum-node-state node) token)
     (+ (enum-node-logprob node) (vector-ref logprobs i))
     (add1 (enum-node-depth node))
     (logits-result-state result)
     (append (enum-node-traces node) (list (logits-result-trace result))))))

(define (enum-node->candidate node)
  (candidate (enum-node-text node)
             (enum-node-tokens node)
             (enum-node-logprob node)
             0.0
             (enum-node-state node)
             (enum-node-traces node)
             (make-empty-sampler-stats)))

(define (candidate-distribution candidates)
  (define z
    (for/sum ([c (in-list candidates)])
      (exp (candidate-logprob c))))
  (for/hash ([c (in-list candidates)])
    (values (candidate-text c)
            (if (zero? z) 0.0 (/ (exp (candidate-logprob c)) z)))))

(define (empirical-top1-distribution provider matcher seed runs max-depth)
  (define counts (make-hash))
  (for ([i (in-range runs)])
    (define ys
      (stream->list
       (gumbel-stream provider
                      matcher
                      (gumbel-config max-depth 1 1000 (+ seed i) 'binary-heap '(tokens))
                      '())))
    (when (pair? ys)
      (hash-update! counts (candidate-text (car ys)) add1 0)))
  (for/hash ([(key count) (in-hash counts)])
    (values key (/ count runs))))

(define (duplicate-rate candidates)
  (if (null? candidates)
      0.0
      (/ (- (length candidates)
            (length (remove-duplicates (map candidate-text candidates))))
         (length candidates))))

(define (order-agreement expected observed)
  (define n (min (length expected) (length observed)))
  (if (zero? n)
      1.0
      (/ (for/sum ([left (in-list expected)]
                   [right (in-list observed)]
                   [_i (in-range n)])
           (if (equal? left right) 1.0 0.0))
         n)))

(define (explicit-gumbel-order candidates seed)
  (define rng (seeded-generator seed))
  (sample-gumbel rng) ; gumbel-stream samples a root priority first.
  (map car
       (sort
        (for/list ([c (in-list candidates)])
          (cons (candidate-text c)
                (+ (candidate-logprob c) (sample-gumbel rng))))
        >
        #:key cdr)))

(define (provider-vocab provider)
  (define vocab-size (provider-info-vocab-size (provider-info provider)))
  (for/vector ([i (in-range vocab-size)])
    ((provider-detokenize provider) (list i))))

(define (distribution-keys p q)
  (remove-duplicates (append (hash-keys p) (hash-keys q))))

(define (seeded-generator seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng])
    (random-seed seed))
  rng)

(define (sample-gumbel rng)
  (define u
    (parameterize ([current-pseudo-random-generator rng])
      (max 1e-12 (min (- 1.0 1e-12) (random)))))
  (- (log (- (log u)))))

(define synthetic-cases
  (list
   (list "enum"
         (make-mock-provider
          #:vocab '("a" "b" "c")
          #:default-logits '#(0.0 -0.5 -1.0))
         (choice (lit "a") (list (lit "b") (lit "c"))))
   (list "brackets"
         (make-mock-provider
          #:vocab '("[" "]" "a" "b")
          #:default-logits '#(0.0 0.0 0.0 0.0))
         (choice (seq (lit "[") (lit "a") (lit "]"))
                 (list (seq (lit "[") (lit "b") (lit "]")))))
   (list "json-like"
         (make-mock-provider
          #:vocab '("{\"status\":\"ok\"}" "{\"status\":\"error\"}")
          #:default-logits '#(0.0 -1.0))
         (json-object
          (list (json-field "status" (json-enum '("ok" "error")) #t))))))

(module+ main
  (require racket/cmdline)

  (define seed 42)
  (define runs 100)
  (command-line
   #:once-each
   [("--seed") value "Seed" (set! seed (string->number value))]
   [("--runs") value "Repeated top-1 samples" (set! runs (string->number value))])
  (write-synthetic-csv
   (current-output-port)
   (run-synthetic-correctness #:seed seed #:runs runs)))
