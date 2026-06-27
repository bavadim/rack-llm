#lang racket/base

(require racket/cmdline
         racket/string
         rack-llm/sampling/agenda)

(define sizes '(1000 10000))
(define include-slow-list? #f)
(define slow-list-limit 10000)

(command-line
 #:program "agenda-bench"
 #:once-each
 [("--sizes") raw "Comma-separated sizes, for example 1000,10000,100000"
              (set! sizes (map string->number (string-split raw ",")))]
 [("--include-slow-list") "Also run list baseline above the default slow-size cap"
                          (set! include-slow-list? #t)])

(define (priorities n)
  (for/list ([i (in-range n)])
    (exact->inexact (- n i))))

(define (run-kind kind n)
  (collect-garbage)
  (define ps (priorities n))
  (define-values (_result cpu real gc)
    (time-apply
     (lambda ()
       (define a
         (for/fold ([a (agenda-empty kind)])
                   ([p (in-list ps)])
           (agenda-push a (agenda-item p p))))
       (let loop ([a a] [count 0])
         (cond
           [(agenda-empty? a) count]
           [else
            (define-values (_item rest) (agenda-pop-max a))
            (loop rest (add1 count))])))
     '()))
  (hash 'kind kind 'n n 'cpu-ms cpu 'real-ms real 'gc-ms gc))

(define (print-row row)
  (printf "~a,n=~a,cpu_ms=~a,real_ms=~a,gc_ms=~a~n"
          (hash-ref row 'kind)
          (hash-ref row 'n)
          (hash-ref row 'cpu-ms)
          (hash-ref row 'real-ms)
          (hash-ref row 'gc-ms))
  (flush-output))

(define (print-skip kind n reason)
  (printf "~a,n=~a,skipped=~a~n" kind n reason)
  (flush-output))

(for ([n (in-list sizes)])
  (unless (and (integer? n) (positive? n))
    (error 'agenda-bench "invalid size: ~a" n))
  (print-row (run-kind 'binary-heap n))
  (print-row (run-kind 'pairing-heap n))
  (cond
    [(or include-slow-list? (<= n slow-list-limit))
     (print-row (run-kind 'list n))]
    [else
     (print-skip 'list n "use --include-slow-list")]))
