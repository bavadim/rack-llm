#lang racket/base

(require json
         rack-llm/rules/acceptance
         rack-llm/sampling/sampler-stats
         "metadata.rkt")

(provide schema-version
         (struct-out candidate-trace)
         candidate-trace->json
         rule-observation->json
         trace-event->json
         write-trace-event)

(define schema-version "1")

(struct candidate-trace
  (run-id
   stream-id
   rank
   candidate-hash
   text
   tokens
   logprob
   gumbel-score
   rule-observations
   constraint-posteriors
   accepted?
   diagnostics
   sampler-stats)
  #:transparent)

(define (candidate-trace->json trace #:redact-text? [redact-text? #f])
  (define base
    (hash 'schema_version schema-version
          'run_id (candidate-trace-run-id trace)
          'stream_id (candidate-trace-stream-id trace)
          'rank (candidate-trace-rank trace)
          'candidate_hash (candidate-trace-candidate-hash trace)
          'text (if redact-text? 'null (candidate-trace-text trace))
          'tokens (candidate-trace-tokens trace)
          'logprob (candidate-trace-logprob trace)
          'gumbel_score (candidate-trace-gumbel-score trace)
          'rule_observations (map rule-observation->json
                                  (candidate-trace-rule-observations trace))
          'constraint_posteriors
          (symbol-flonum-hash->json (candidate-trace-constraint-posteriors trace))
          'accepted (candidate-trace-accepted? trace)
          'diagnostics (candidate-trace-diagnostics trace)))
  (define stats (candidate-trace-sampler-stats trace))
  (if stats
      (add-sampler-stats base stats)
      base))

(define (rule-observation->json observation)
  (hash 'rule_id (symbol->string (rule-observation-rule-id observation))
        'decision (symbol->string (rule-observation-decision observation))
        'message (or (rule-observation-message observation) 'null)
        'metadata (rule-observation-metadata observation)))

(define (trace-event->json event payload #:redact-text? [redact-text? #f])
  (hash 'schema_version schema-version
        'event (symbol->string event)
        'payload (trace-payload->json payload #:redact-text? redact-text?)))

(define (write-trace-event out event payload #:redact-text? [redact-text? #f])
  (write-json (trace-event->json event payload #:redact-text? redact-text?) out)
  (newline out))

(define (trace-payload->json payload #:redact-text? [redact-text? #f])
  (cond
    [(candidate-trace? payload)
     (candidate-trace->json payload #:redact-text? redact-text?)]
    [(run-metadata? payload)
     (run-metadata->json payload)]
    [(hash? payload) payload]
    [else payload]))

(define (symbol-flonum-hash->json table)
  (for/hash ([(key value) (in-hash table)])
    (values (symbol->string key) value)))

(define (add-sampler-stats base stats)
  (define stats-json (sampler-stats->json stats))
  (for/fold ([acc (hash-set base 'sampler_stats stats-json)])
            ([(key value) (in-hash stats-json)])
    (hash-set acc key value)))
