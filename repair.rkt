#lang racket/base

(require rack-llm
         rack-llm/rules/threshold-acceptance)

(provide (struct-out repair-config)
         make-repair-transcript)

(struct repair-config
  (enabled?
   max-rounds
   diagnostics-limit)
  #:transparent)

(define default-diagnostics-limit 5)

(define (make-repair-transcript transcript candidate decision)
  (append transcript
          (list
           (user
            (lit
             (repair-message candidate
                             (acceptance-decision-diagnostics decision)
                             default-diagnostics-limit))))))

(define (repair-message candidate diagnostics limit)
  (string-append
   "Previous candidate was rejected.\n"
   "Candidate:\n"
   (candidate->string candidate)
   "\n\nRule failures:\n"
   (diagnostics->bullets diagnostics limit)
   "\nRegenerate a corrected answer."))

(define (candidate->string candidate)
  (if (string? candidate) candidate (format "~a" candidate)))

(define (diagnostics->bullets diagnostics limit)
  (cond
    [(null? diagnostics) "- no diagnostic detail"]
    [else
     (let loop ([remaining diagnostics]
                [n limit]
                [acc '()])
       (cond
         [(or (zero? n) (null? remaining))
          (join-lines (reverse acc))]
         [else
          (loop (cdr remaining)
                (sub1 n)
                (cons (string-append "- " (car remaining)) acc))]))]))

(define (join-lines lines)
  (cond
    [(null? lines) ""]
    [(null? (cdr lines)) (car lines)]
    [else (string-append (car lines) "\n" (join-lines (cdr lines)))]))
