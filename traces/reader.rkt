#lang racket/base

(require json)

(provide read-trace-events
         selected-candidate-rank)

(define (read-trace-events in)
  (let loop ([events '()])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (reverse events)]
      [(string=? line "") (loop events)]
      [else (loop (cons (string->jsexpr line) events))])))

(define (selected-candidate-rank events)
  (cond
    [(null? events) #f]
    [else
     (define event (car events))
     (define rank
       (and (hash? event)
            (equal? (hash-ref event 'event #f) "candidate")
            (let ([payload (hash-ref event 'payload #f)])
              (and (hash? payload)
                   (hash-ref payload 'accepted #f)
                   (hash-ref payload 'rank #f)))))
     (or rank (selected-candidate-rank (cdr events)))]))
