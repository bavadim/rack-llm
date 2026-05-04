#lang racket/base

(require racket/format
         racket/list
         racket/string
         (for-syntax racket/base)
         "core.rkt"
         "result.rkt"
         "review.rkt")

(provide define-grammar
         emit
         gen
         select
         pick
         best-of)

(define current-state-box (make-parameter #f))

(define (current-state who)
  (define b (current-state-box))
  (unless b
    (error who "used outside define-grammar"))
  (unbox b))

(define (set-current-state! who st)
  (define b (current-state-box))
  (unless b
    (error who "used outside define-grammar"))
  (set-box! b st)
  st)

(define-syntax-rule (define-grammar (name arg ...) body ...)
  (define (name arg ...)
    (lambda (st0)
      (define b (box st0))
      (parameterize ([current-state-box b])
        body ...
        (unbox b)))))

(define (emit value)
  (define text (format "~a" value))
  (set-current-state! 'emit
                      (state-append-buffer (current-state 'emit) text))
  text)

(define (capture! key value)
  (when key
    (set-current-state! 'capture!
                        (state-capture (current-state 'capture!) key value)))
  value)

(define (regexp-full-match? rx s)
  (define m (regexp-match rx s))
  (and m (equal? (car m) s)))

(define (constraint-description rx grammar-spec json-schema)
  (string-join
   (filter values
           (list
            (and rx (format "- The fragment must match this Racket regexp: ~s" rx))
            (and grammar-spec (format "- The fragment must follow this grammar: ~s" grammar-spec))
            (and json-schema (format "- The fragment must satisfy this JSON Schema: ~s" json-schema))))
   "\n"))

(define (continuation-messages st rx grammar-spec json-schema)
  (define constraints (constraint-description rx grammar-spec json-schema))
  (append
   (llm-state-messages st)
   (list
    (hash 'role "system"
          'content
          "Continue the assistant output. Return only the next fragment. Do not explain, quote, wrap in Markdown, or repeat the existing prefix.")
    (hash 'role "user"
          'content
          (format "Assistant output so far:\n~a\n\nGenerate the next fragment.~a"
                  (llm-state-buffer st)
                  (if (string=? constraints "")
                      ""
                      (format "\n\nConstraints:\n~a" constraints)))))))

(define (gen #:as [as #f]
             #:max-tokens [max-tokens #f]
             #:regex [rx #f]
             #:grammar [grammar-spec #f]
             #:json-schema [json-schema #f]
             #:temperature [temperature #f]
             #:stop [stop #f]
             #:extra [extra (hash)])
  (define st (current-state 'gen))
  (define raw
    (model-complete (llm-state-model st)
                    (continuation-messages st rx grammar-spec json-schema)
                    #:max-tokens max-tokens
                    #:temperature temperature
                    #:stop stop
                    #:extra extra))
  (define text (string-trim raw))
  (when (and rx (not (regexp-full-match? rx text)))
    (error 'gen "model output did not match regexp; output=~s regexp=~s" text rx))
  (emit text)
  (capture! as text)
  text)

(define (options->list options)
  (for/list ([o options]) o))

(define (render-option show option)
  (format "~a" (show option)))

(define (choose-index st options show temperature)
  (cond
    [(null? options)
     (error 'select "empty options")]
    [(null? (cdr options)) 0]
    [else
     (define rendered
       (for/list ([option (in-list options)] [i (in-naturals)])
         (format "~a. ~a" i (render-option show option))))
     (define prompt
       (format "Choose exactly one option index. Output only the integer index.\n\nCurrent assistant output:\n~a\n\nOptions:\n~a"
               (llm-state-buffer st)
               (string-join rendered "\n")))
     (define answer
       (model-complete (llm-state-model st)
                       (append (llm-state-messages st)
                               (list
                                (hash 'role "system"
                                      'content "You choose from finite options. Output only one integer index, nothing else.")
                                (hash 'role "user" 'content prompt)))
                       #:max-tokens 8
                       #:temperature (or temperature 0.0)))
     (define m (regexp-match #px"[0-9]+" answer))
     (unless m
       (error 'select "model did not return an option index; output=~s" answer))
     (define idx (string->number (car m)))
     (unless (and (exact-nonnegative-integer? idx)
                  (< idx (length options)))
       (error 'select "model returned option index out of range; output=~s" answer))
     idx]))

(define (select options
                #:as [as #f]
                #:show [show ~a]
                #:temperature [temperature #f])
  (define st (current-state 'select))
  (define opts (options->list options))
  (define idx (choose-index st opts show temperature))
  (define selected (list-ref opts idx))
  (capture! as selected)
  (emit (render-option show selected))
  selected)

(define (pick options
              #:as [as #f]
              #:show [show ~a]
              #:temperature [temperature #f])
  (define st (current-state 'pick))
  (define opts (options->list options))
  (define idx (choose-index st opts show temperature))
  (define selected (list-ref opts idx))
  (capture! as selected)
  selected)

(define (run-grammar-attempt grammar base-st attempt)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (candidate "" base-st (llm-state-captures base-st)
                                (llm-state-trace base-st) attempt e))])
    (define before-buffer (llm-state-buffer base-st))
    (define trial-st (grammar base-st))
    (define after-buffer (llm-state-buffer trial-st))
    (define produced
      (if (and (<= (string-length before-buffer) (string-length after-buffer))
               (string-prefix? after-buffer before-buffer))
          (substring after-buffer (string-length before-buffer))
          after-buffer))
    (candidate produced
               trial-st
               (llm-state-captures trial-st)
               (llm-state-trace trial-st)
               attempt
               #f)))

(define (evaluate-reviewers ctx cand reviewers)
  (if (candidate-error cand)
      '()
      (for/list ([wr (in-list reviewers)])
        (define reviewer (weighted-reviewer-reviewer wr))
        (define rev (reviewer ctx cand))
        (define w0 (weighted-reviewer-weight wr))
        (define w (if (procedure? w0) (w0 ctx cand rev) w0))
        (evaluated-review w reviewer rev))))

(define (best-of grammar
                 #:as [as #f]
                 #:tries [tries 4]
                 #:context [ctx #f]
                 #:reviewers [reviewers '()]
                 #:weigh [weigh weighted-score]
                 #:min-score [min-score -inf.0]
                 #:on-fail [on-fail 'return-best])
  (lambda (st0)
    (define evaluated
      (for/list ([attempt (in-range tries)])
        (define cand (run-grammar-attempt grammar st0 attempt))
        (define reviews (evaluate-reviewers ctx cand reviewers))
        (define score
          (if (candidate-error cand)
              -inf.0
              (weigh ctx cand reviews)))
        (list cand reviews score)))

    (define best
      (argmax (lambda (item) (third item)) evaluated))
    (define best-cand (first best))
    (define best-score (third best))

    (cond
      [(candidate-error best-cand)
       (raise (candidate-error best-cand))]
      [(and (< best-score min-score) (eq? on-fail 'raise))
       (error 'best-of "best candidate score below #:min-score; score=~a min-score=~a text=~s"
              best-score min-score (candidate-text best-cand))]
      [else
       (define st1 (candidate-state best-cand))
       (if as
           (state-capture st1 as (candidate-text best-cand))
           st1)])))
