#lang racket/base

(provide (struct-out sampler-stats)
         make-empty-sampler-stats
         sampler-stats-add
         sampler-stats-snapshot
         sampler-stats->json)

(struct sampler-stats
  (expanded-nodes
   created-edges
   agenda-pushes
   agenda-pops
   max-frontier
   provider-calls
   grammar-checks
   yielded-candidates)
  #:transparent)

(define (make-empty-sampler-stats)
  (sampler-stats 0 0 0 0 0 0 0 0))

(define (sampler-stats-snapshot stats-box)
  (unbox stats-box))

(define (sampler-stats-add stats-box
                           #:expanded-nodes [expanded-nodes 0]
                           #:created-edges [created-edges 0]
                           #:agenda-pushes [agenda-pushes 0]
                           #:agenda-pops [agenda-pops 0]
                           #:max-frontier [max-frontier #f]
                           #:provider-calls [provider-calls 0]
                           #:grammar-checks [grammar-checks 0]
                           #:yielded-candidates [yielded-candidates 0])
  (define current (unbox stats-box))
  (set-box!
   stats-box
   (sampler-stats
    (+ (sampler-stats-expanded-nodes current) expanded-nodes)
    (+ (sampler-stats-created-edges current) created-edges)
    (+ (sampler-stats-agenda-pushes current) agenda-pushes)
    (+ (sampler-stats-agenda-pops current) agenda-pops)
    (max (sampler-stats-max-frontier current) (or max-frontier 0))
    (+ (sampler-stats-provider-calls current) provider-calls)
    (+ (sampler-stats-grammar-checks current) grammar-checks)
    (+ (sampler-stats-yielded-candidates current) yielded-candidates))))

(define (sampler-stats->json stats)
  (hash 'expanded_nodes (sampler-stats-expanded-nodes stats)
        'created_edges (sampler-stats-created-edges stats)
        'agenda_pushes (sampler-stats-agenda-pushes stats)
        'agenda_pops (sampler-stats-agenda-pops stats)
        'max_frontier (sampler-stats-max-frontier stats)
        'provider_calls (sampler-stats-provider-calls stats)
        'grammar_checks (sampler-stats-grammar-checks stats)
        'yielded_candidates (sampler-stats-yielded-candidates stats)))
