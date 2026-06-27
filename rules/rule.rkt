#lang typed/racket/base

(provide RuleDecision
         RuleResult
         Rule
         (struct-out rule-result)
         (struct-out rule)
         accept
         reject
         abstain
         apply-rule)

(define-type RuleDecision (U 'accept 'reject 'abstain))
(define-type RuleResult rule-result)
(define-type Rule rule)

(struct rule-result
  ([decision : RuleDecision]
   [message : (Option String)]
   [metadata : (HashTable Symbol Any)]
   [cost-ms : Nonnegative-Flonum])
  #:transparent)

(struct rule
  ([id : Symbol]
   [description : String]
   [scope : Symbol]
   [run : (-> Any rule-result)])
  #:transparent)

(: accept (->* () (#:message (Option String)
                   #:metadata (HashTable Symbol Any))
              rule-result))
(define (accept #:message [message #f]
                #:metadata [metadata (ann (hash) (HashTable Symbol Any))])
  (rule-result 'accept message metadata 0.0))

(: reject (->* () (#:message (Option String)
                   #:metadata (HashTable Symbol Any))
              rule-result))
(define (reject #:message [message #f]
                #:metadata [metadata (ann (hash) (HashTable Symbol Any))])
  (rule-result 'reject message metadata 0.0))

(: abstain (->* () (#:message (Option String)
                    #:metadata (HashTable Symbol Any))
               rule-result))
(define (abstain #:message [message #f]
                 #:metadata [metadata (ann (hash) (HashTable Symbol Any))])
  (rule-result 'abstain message metadata 0.0))

(: apply-rule (-> rule Any rule-result))
(define (apply-rule r candidate)
  ((rule-run r) candidate))
