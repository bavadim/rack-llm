#lang racket/base

(require rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene)

(provide (struct-out acceptance-config)
         (struct-out acceptance-decision)
         accept-candidate
         accept-posteriors)

(struct acceptance-config
  (mode
   default-threshold
   constraint-thresholds
   weights)
  #:transparent)

(struct acceptance-decision
  (accepted?
   hard-passed?
   score
   constraint-posteriors
   diagnostics)
  #:transparent)

(define (accept-candidate config hard-report ds-model constraint-observations)
  (define posteriors (constraint-posteriors ds-model constraint-observations))
  (accept-posteriors config hard-report posteriors))

(define (accept-posteriors config hard-report posteriors)
  (define score (score-posteriors config posteriors))
  (define diagnostics
    (append (acceptance-report-diagnostics hard-report)
            (threshold-diagnostics config posteriors)))
  (define accepted?
    (and (acceptance-report-hard-passed? hard-report)
         (threshold-passed? config posteriors score)))
  (acceptance-decision accepted?
                       (acceptance-report-hard-passed? hard-report)
                       score
                       posteriors
                       (if (acceptance-report-hard-passed? hard-report)
                           diagnostics
                           (cons "hard rules failed" diagnostics))))

(define (threshold-passed? config posteriors score)
  (case (acceptance-config-mode config)
    [(all-constraints)
     (for/and ([(constraint-id posterior) (in-hash posteriors)])
       (>= posterior (constraint-threshold config constraint-id)))]
    [(weighted-sum min-posterior)
     (>= score (acceptance-config-default-threshold config))]
    [else (error 'accept-candidate
                 "unsupported acceptance mode: ~a"
                 (acceptance-config-mode config))]))

(define (score-posteriors config posteriors)
  (case (acceptance-config-mode config)
    [(all-constraints min-posterior)
     (min-posterior posteriors)]
    [(weighted-sum)
     (weighted-score config posteriors)]
    [else (error 'accept-candidate
                 "unsupported acceptance mode: ~a"
                 (acceptance-config-mode config))]))

(define (min-posterior posteriors)
  (cond
    [(zero? (hash-count posteriors)) 0.0]
    [else (apply min (hash-values posteriors))]))

(define (weighted-score config posteriors)
  (cond
    [(zero? (hash-count posteriors)) 0.0]
    [else
     (define weighted
       (for/list ([(constraint-id posterior) (in-hash posteriors)])
         (define weight (constraint-weight config constraint-id))
         (cons weight (* weight posterior))))
     (define denominator (apply + (map car weighted)))
     (if (zero? denominator)
         0.0
         (/ (apply + (map cdr weighted)) denominator))]))

(define (threshold-diagnostics config posteriors)
  (case (acceptance-config-mode config)
    [(all-constraints)
     (for/list ([(constraint-id posterior) (in-hash posteriors)]
                #:when (< posterior (constraint-threshold config constraint-id)))
       (format "constraint ~a below threshold" constraint-id))]
    [(weighted-sum)
     (if (< (weighted-score config posteriors)
            (acceptance-config-default-threshold config))
         (list "weighted constraint score below threshold")
         '())]
    [(min-posterior)
     (if (< (min-posterior posteriors)
            (acceptance-config-default-threshold config))
         (list "minimum constraint posterior below threshold")
         '())]
    [else '()]))

(define (constraint-threshold config constraint-id)
  (hash-ref (acceptance-config-constraint-thresholds config)
            constraint-id
            (lambda () (acceptance-config-default-threshold config))))

(define (constraint-weight config constraint-id)
  (hash-ref (acceptance-config-weights config)
            constraint-id
            (lambda () 1.0)))
