#lang racket/base

(require racket/stream
         "../grammar.rkt"
         "../grammar/mask.rkt"
         "../providers/provider-v2.rkt"
         "agenda.rkt"
         "dedupe.rkt"
         "sampler-stats.rkt")

(provide (struct-out gumbel-config)
         (struct-out candidate)
         gumbel-stream
         gumbel-stream/stats
         collect-gumbel-stream)

(struct gumbel-config
  (max-depth
   max-candidates
   max-expanded-nodes
   seed
   agenda-kind
   dedupe)
  #:transparent)

(struct candidate
  (text
   tokens
   logprob
   gumbel-score
   matcher-state
   provider-traces
   stats)
  #:transparent)

(struct frontier-node
  (text
   tokens
   matcher-state
   logprob
   gumbel-score
   depth
   provider-state
   provider-traces)
  #:transparent)

(define (gumbel-stream provider matcher config transcript)
  (define-values (ys _stats) (gumbel-stream/stats provider matcher config transcript))
  ys)

(define (gumbel-stream/stats provider matcher config transcript)
  (define stats-box (box (make-empty-sampler-stats)))
  (define rng (seeded-generator (gumbel-config-seed config)))
  (define vocab (provider-vocab provider))
  (define dedupe-filter
    (make-dedupe-filter (gumbel-config-dedupe config) #f))
  (define root
    (frontier-node ""
                   '()
                   (matcher-start matcher)
                   0.0
                   (sample-gumbel rng)
                   0
                   (provider-initial-state provider)
                   '()))
  (define initial-agenda
    (agenda-push (agenda-empty (gumbel-config-agenda-kind config))
                 (node->agenda-item root)))
  (sampler-stats-add stats-box
                     #:agenda-pushes 1
                     #:max-frontier (agenda-size initial-agenda))
  (values
   (step provider matcher config transcript vocab dedupe-filter rng stats-box initial-agenda 0 0)
   stats-box))

(define (collect-gumbel-stream provider matcher config transcript)
  (define-values (ys stats-box)
    (gumbel-stream/stats provider matcher config transcript))
  (values (stream->list ys) (sampler-stats-snapshot stats-box)))

(define (step provider matcher config transcript vocab dedupe-filter rng stats-box agenda yielded expanded)
  (cond
    [(or (agenda-empty? agenda)
         (>= yielded (gumbel-config-max-candidates config))
         (>= expanded (gumbel-config-max-expanded-nodes config)))
     empty-stream]
    [else
     (define-values (item rest-agenda) (agenda-pop-max agenda))
     (sampler-stats-add stats-box #:agenda-pops 1)
     (define node (agenda-item-payload item))
     (define accepting? (matcher-accepting? (frontier-node-matcher-state node)))
     (define should-expand? (< (frontier-node-depth node)
                               (gumbel-config-max-depth config)))
     (define-values (next-agenda next-expanded)
       (if should-expand?
           (expand-into-agenda provider
                               matcher
                               transcript
                               vocab
                               rng
                               stats-box
                               rest-agenda
                               node
                               expanded)
           (values rest-agenda expanded)))
     (cond
       [(and accepting?
             (dedupe-filter
              (dedupe-candidate (frontier-node-text node)
                                (frontier-node-tokens node)
                                #f)))
        (sampler-stats-add stats-box #:yielded-candidates 1)
        (stream-cons
         (node->candidate node (sampler-stats-snapshot stats-box))
         (step provider
               matcher
               config
               transcript
               vocab
               dedupe-filter
               rng
               stats-box
               next-agenda
               (add1 yielded)
               next-expanded))]
       [else
        (step provider
              matcher
              config
              transcript
              vocab
              dedupe-filter
              rng
              stats-box
              next-agenda
              yielded
              next-expanded)])]))

(define (expand-into-agenda provider matcher transcript vocab rng stats-box agenda node expanded)
  (define result
    ((provider-next-logits provider)
     transcript
     (frontier-node-text node)
     (frontier-node-provider-state node)))
  (define logits (logits-result-logits result))
  (define mask (allowed-token-mask matcher (frontier-node-matcher-state node) vocab))
  (define logprobs (normalize-masked-logits (mask-logits logits mask)))
  (define children
    (condition-children
     (frontier-node-gumbel-score node)
     (for/list ([i (in-range (vector-length logprobs))]
                #:when (usable-logprob? (vector-ref logprobs i)))
       (child-node provider
                   matcher
                   node
                   (logits-result-state result)
                   (logits-result-trace result)
                   i
                   (vector-ref vocab i)
                   (vector-ref logprobs i)
                   rng))))
  (define next-agenda
    (foldl (lambda (child acc)
             (agenda-push acc (node->agenda-item child)))
           agenda
           children))
  (sampler-stats-add stats-box
                     #:expanded-nodes 1
                     #:created-edges (length children)
                     #:agenda-pushes (length children)
                     #:max-frontier (agenda-size next-agenda)
                     #:provider-calls 1
                     #:grammar-checks (vector-length vocab))
  (values next-agenda (add1 expanded)))

(define (child-node provider matcher parent provider-state trace token-id token-text logprob rng)
  (define child-logprob (+ (frontier-node-logprob parent) logprob))
  (frontier-node
   (string-append (frontier-node-text parent) token-text)
   (append (frontier-node-tokens parent) (list token-id))
   (matcher-advance matcher (frontier-node-matcher-state parent) token-text)
   child-logprob
   (+ child-logprob (sample-gumbel rng))
   (add1 (frontier-node-depth parent))
   provider-state
   (append (frontier-node-provider-traces parent) (list trace))))

(define (condition-children parent-g children)
  (cond
    [(null? children) '()]
    [else
     (define raw-max (apply max (map frontier-node-gumbel-score children)))
     (map (lambda (child)
            (struct-copy frontier-node child
                         [gumbel-score
                          (condition-gumbel parent-g
                                            (frontier-node-gumbel-score child)
                                            raw-max)]))
          children)]))

(define (node->candidate node stats)
  (candidate (frontier-node-text node)
             (frontier-node-tokens node)
             (frontier-node-logprob node)
             (frontier-node-gumbel-score node)
             (frontier-node-matcher-state node)
             (frontier-node-provider-traces node)
             stats))

(define (node->agenda-item node)
  (agenda-item (frontier-node-gumbel-score node) node))

(define (provider-vocab provider)
  (define vocab-size (provider-info-vocab-size (provider-info provider)))
  (for/vector ([i (in-range vocab-size)])
    ((provider-detokenize provider) (list i))))

(define (usable-logprob? x)
  (> x -1e300))

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

(define (condition-gumbel parent-g raw-child-g raw-max)
  (define mass
    (+ (- (exp (- parent-g))
          (exp (- raw-max)))
       (exp (- raw-child-g))))
  (- (log (max 1e-300 mass))))
