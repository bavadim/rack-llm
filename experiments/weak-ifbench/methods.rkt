#lang racket/base

(require rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/heuristics
         rack-llm/rules/acceptance
         rack-llm/rules/aggregation-baselines
         rack-llm/rules/dawid-skene
         rack-llm/rules/threshold-acceptance
         rack-llm/traces/trace)

(provide method-ids
         (struct-out candidate)
         (struct-out experiment-context)
         (struct-out method-result)
         run-method)

(define method-ids
  '(pass1
    independent-sampling
    independent-majority
    independent-ds
    gumbel-majority
    gumbel-ds
    oracle-verifier))

(struct candidate
  (rank
   text
   score
   metadata)
  #:transparent)

(struct experiment-context
  (candidate-generator
   ds-model
   acceptance-config)
  #:transparent)

(struct method-result
  (method
   task-id
   budget
   selected
   trace)
  #:transparent)

(struct scored-candidate
  (candidate
   trace
   accepted?
   score)
  #:transparent)

(define (run-method method ctx task budget)
  (unless (memq method method-ids)
    (error 'run-method "unsupported method: ~a" method))
  (when (and (eq? method 'pass1) (not (= budget 1)))
    (error 'run-method "pass1 requires budget 1, got ~a" budget))
  (define candidates
    ((experiment-context-candidate-generator ctx) task budget))
  (define scored
    (case method
      [(pass1 independent-sampling)
       (score-rank-only method task candidates)]
      [(independent-majority gumbel-majority)
       (score-aggregated method ctx task candidates 'majority)]
      [(independent-ds gumbel-ds)
       (score-ds method ctx task candidates)]
      [(oracle-verifier)
       (score-oracle method task candidates)]))
  (method-result method
                 (ifbench-task-id task)
                 budget
                 (and (not (null? scored))
                      (scored-candidate-candidate (select-scored scored)))
                 (map scored-candidate-trace scored)))

(define (score-rank-only method task candidates)
  (define selected-rank (and (not (null? candidates))
                             (candidate-rank (car candidates))))
  (for/list ([cand (in-list candidates)])
    (define selected? (= (candidate-rank cand) selected-rank))
    (scored-candidate cand
                      (candidate->trace method task cand (hash) '() selected? '())
                      selected?
                      (candidate-score cand))))

(define (score-aggregated method ctx task candidates mode)
  (for/list ([cand (in-list candidates)])
    (define observations (constraint-observations-for-candidate task (candidate-text cand)))
    (define posteriors (baseline-constraint-posteriors mode observations))
    (define report (acceptance-report #t
                                      (map constraint-observation-rule-observation observations)
                                      '()))
    (define decision
      (accept-posteriors (context-acceptance-config ctx) report posteriors))
    (scored-candidate cand
                      (candidate->trace method
                                        task
                                        cand
                                        posteriors
                                        (acceptance-report-observations report)
                                        (acceptance-decision-accepted? decision)
                                        (acceptance-decision-diagnostics decision))
                      (acceptance-decision-accepted? decision)
                      (acceptance-decision-score decision))))

(define (score-ds method ctx task candidates)
  (for/list ([cand (in-list candidates)])
    (define observations (constraint-observations-for-candidate task (candidate-text cand)))
    (define posteriors
      (if (experiment-context-ds-model ctx)
          (constraint-posteriors (experiment-context-ds-model ctx) observations)
          (default-constraint-posteriors observations)))
    (define report (acceptance-report #t
                                      (map constraint-observation-rule-observation observations)
                                      '()))
    (define decision
      (accept-posteriors (context-acceptance-config ctx) report posteriors))
    (scored-candidate cand
                      (candidate->trace method
                                        task
                                        cand
                                        posteriors
                                        (acceptance-report-observations report)
                                        (acceptance-decision-accepted? decision)
                                        (acceptance-decision-diagnostics decision))
                      (acceptance-decision-accepted? decision)
                      (acceptance-decision-score decision))))

(define (score-oracle method task candidates)
  (for/list ([cand (in-list candidates)])
    (define verdict (run-gold-verifier task (candidate-text cand)))
    (define passed? (gold-verdict-prompt-passed? verdict))
    (scored-candidate cand
                      (candidate->trace method
                                        task
                                        cand
                                        (constraint-results->posteriors
                                         (gold-verdict-constraint-results verdict))
                                        '()
                                        passed?
                                        (list "oracle upper bound: uses gold verifier"))
                      passed?
                      (if passed? 1.0 0.0))))

(define (select-scored scored)
  (or (first-accepted scored)
      (best-score scored)
      (car scored)))

(define (first-accepted scored)
  (cond
    [(null? scored) #f]
    [(scored-candidate-accepted? (car scored)) (car scored)]
    [else (first-accepted (cdr scored))]))

(define (best-score scored)
  (cond
    [(null? scored) #f]
    [else
     (let loop ([best (car scored)]
                [rest (cdr scored)])
       (cond
         [(null? rest) best]
         [(> (scored-candidate-score (car rest))
             (scored-candidate-score best))
          (loop (car rest) (cdr rest))]
         [else (loop best (cdr rest))]))]))

(define (constraint-observations-for-candidate task text)
  (apply append
         (for/list ([constraint (in-list (ifbench-task-constraints task))])
           (define report
             (run-rules
              (acceptance-input text (weak-rules-for-constraint constraint))))
           (for/list ([observation (in-list (acceptance-report-observations report))])
             (constraint-observation (constraint-spec-id constraint) observation)))))

(define (default-constraint-posteriors observations)
  (for/hash ([constraint-id (in-list (constraint-ids observations))])
    (values constraint-id 0.5)))

(define (constraint-results->posteriors results)
  (for/hash ([(constraint-id passed?) (in-hash results)])
    (values constraint-id (if passed? 1.0 0.0))))

(define (constraint-ids observations)
  (reverse
   (for/fold ([ids '()])
             ([observation (in-list observations)])
     (define constraint-id (constraint-observation-constraint-id observation))
     (if (memq constraint-id ids)
         ids
         (cons constraint-id ids)))))

(define (context-acceptance-config ctx)
  (or (experiment-context-acceptance-config ctx)
      (acceptance-config 'all-constraints 0.5 (hash) (hash))))

(define (candidate->trace method task cand posteriors observations accepted? diagnostics)
  (candidate-trace (format "~a/~a" method (ifbench-task-id task))
                   0
                   (candidate-rank cand)
                   (number->string (equal-hash-code (candidate-text cand)))
                   (candidate-text cand)
                   '()
                   (candidate-score cand)
                   (candidate-score cand)
                   observations
                   posteriors
                   accepted?
                   diagnostics
                   #f))
