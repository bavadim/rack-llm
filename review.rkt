#lang racket/base

(require racket/match
         "result.rkt")

(provide (struct-out review)
         (struct-out weighted-reviewer)
         (struct-out evaluated-review)
         pass
         fail
         abstain
         weighted
         weighted-score
         review-verdict/c)

(define review-verdict/c '(pass fail abstain))

(struct review
  (verdict    ; 'pass | 'fail | 'abstain
   score      ; Real, conventionally [-1, 1]
   reason     ; String
   hint       ; String
   data)      ; Any
  #:transparent)

(struct weighted-reviewer
  (weight     ; Real or procedure: ctx cand review -> Real
   reviewer)  ; procedure: ctx cand -> review
  #:transparent)

(struct evaluated-review
  (weight reviewer review)
  #:transparent)

(define (pass #:score [score 1.0]
              #:reason [reason ""]
              #:hint [hint ""]
              #:data [data #f])
  (review 'pass score reason hint data))

(define (fail reason
              #:score [score -1.0]
              #:hint [hint ""]
              #:data [data #f])
  (review 'fail score reason hint data))

(define (abstain #:reason [reason ""]
                 #:hint [hint ""]
                 #:data [data #f])
  (review 'abstain 0.0 reason hint data))

(define (weighted weight reviewer)
  (weighted-reviewer weight reviewer))

(define (resolve-weight weight ctx cand rev)
  (cond
    [(procedure? weight) (weight ctx cand rev)]
    [else weight]))

(define (weighted-score ctx cand evaluated-reviews)
  (for/sum ([er (in-list evaluated-reviews)])
    (define rev (evaluated-review-review er))
    (case (review-verdict rev)
      [(abstain) 0.0]
      [else (* (evaluated-review-weight er)
               (review-score rev))])))
