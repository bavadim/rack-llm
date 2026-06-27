#lang typed/racket/base

(require "rule.rkt")

(provide all-of
         any-of
         at-least
         exactly
         none-of
         implies
         (struct-out weighted-rule)
         hard
         soft
         rule-at-least)

(struct weighted-rule
  ([rule : rule]
   [kind : (U 'hard 'soft)]
   [weight : (Option Flonum)])
  #:transparent)

(: all-of (-> Symbol String (Listof rule) rule))
(define (all-of id description rules)
  (compound-rule id description rules all-of-decision))

(: any-of (-> Symbol String (Listof rule) rule))
(define (any-of id description rules)
  (compound-rule id description rules any-of-decision))

(: at-least (-> Symbol String Natural (Listof rule) rule))
(define (at-least id description k rules)
  (compound-rule id description rules (lambda ([results : (Listof rule-result)])
                                        (at-least-decision k results))))

(: exactly (-> Symbol String Natural (Listof rule) rule))
(define (exactly id description k rules)
  (compound-rule id description rules (lambda ([results : (Listof rule-result)])
                                        (exactly-decision k results))))

(: none-of (-> Symbol String (Listof rule) rule))
(define (none-of id description rules)
  (compound-rule id description rules none-of-decision))

(: implies (-> Symbol String rule rule rule))
(define (implies id description antecedent consequent)
  (rule id
        description
        'candidate
        (lambda ([candidate : Any])
          (define antecedent-result (apply-rule antecedent candidate))
          (cond
            [(eq? (rule-result-decision antecedent-result) 'accept)
             (define consequent-result (apply-rule consequent candidate))
             (rule-result
              (rule-result-decision consequent-result)
              (rule-result-message consequent-result)
              (compound-metadata
               (list (child-result antecedent antecedent-result)
                     (child-result consequent consequent-result)))
              0.0)]
            [else
             (abstain #:metadata
                      (compound-metadata
                       (list (child-result antecedent antecedent-result))))]))))

(: hard (-> rule weighted-rule))
(define (hard r)
  (weighted-rule r 'hard #f))

(: soft (->* (rule) (#:weight Flonum) weighted-rule))
(define (soft r #:weight [weight 1.0])
  (weighted-rule r 'soft weight))

(: rule-at-least (-> Natural (Listof rule) rule))
(define (rule-at-least k rules)
  (at-least 'rule-at-least
            (format "accept when at least ~a rules accept" k)
            k
            rules))

(define-type DecisionFn (-> (Listof rule-result) RuleDecision))

(: compound-rule (-> Symbol String (Listof rule) DecisionFn rule))
(define (compound-rule id description rules decide)
  (rule id
        description
        'candidate
        (lambda ([candidate : Any])
          (define children
            (map (lambda ([r : rule])
                   (child-result r (apply-rule r candidate)))
                 rules))
          (define results
            (map child-result-result children))
          (define decision (decide results))
          (rule-result decision
                       #f
                       (compound-metadata children)
                       0.0))))

(struct child-result
  ([rule : rule]
   [result : rule-result])
  #:transparent)

(: compound-metadata (-> (Listof child-result) (HashTable Symbol Any)))
(define (compound-metadata children)
  (hash 'children (map child-result->metadata children)
        'accepts (count-decision 'accept (map child-result-result children))
        'rejects (count-decision 'reject (map child-result-result children))
        'abstains (count-decision 'abstain (map child-result-result children))))

(: child-result->metadata (-> child-result (HashTable Symbol Any)))
(define (child-result->metadata child)
  (define r (child-result-rule child))
  (define result (child-result-result child))
  (hash 'rule-id (rule-id r)
        'decision (rule-result-decision result)
        'message (or (rule-result-message result) 'null)
        'metadata (rule-result-metadata result)
        'cost-ms (rule-result-cost-ms result)))

(: count-decision (-> RuleDecision (Listof rule-result) Natural))
(define (count-decision decision results)
  (length
   (filter (lambda ([result : rule-result])
             (eq? decision (rule-result-decision result)))
           results)))

(: all-of-decision DecisionFn)
(define (all-of-decision results)
  (cond
    [(any-decision? 'reject results) 'reject]
    [(and (not (null? results)) (all-decision? 'accept results)) 'accept]
    [(null? results) 'accept]
    [else 'abstain]))

(: any-of-decision DecisionFn)
(define (any-of-decision results)
  (cond
    [(any-decision? 'accept results) 'accept]
    [(and (not (null? results)) (all-decision? 'reject results)) 'reject]
    [(null? results) 'reject]
    [else 'abstain]))

(: at-least-decision (-> Natural (Listof rule-result) RuleDecision))
(define (at-least-decision k results)
  (define accepts (count-decision 'accept results))
  (define rejects (count-decision 'reject results))
  (cond
    [(>= accepts k) 'accept]
    [(> rejects (- (length results) k)) 'reject]
    [else 'abstain]))

(: exactly-decision (-> Natural (Listof rule-result) RuleDecision))
(define (exactly-decision k results)
  (define accepts (count-decision 'accept results))
  (define possible (+ accepts (count-decision 'abstain results)))
  (cond
    [(and (= accepts k)
          (= possible k))
     'accept]
    [(or (> accepts k)
         (< possible k))
     'reject]
    [else 'abstain]))

(: none-of-decision DecisionFn)
(define (none-of-decision results)
  (cond
    [(any-decision? 'accept results) 'reject]
    [(and (not (null? results)) (all-decision? 'reject results)) 'accept]
    [(null? results) 'accept]
    [else 'abstain]))

(: any-decision? (-> RuleDecision (Listof rule-result) Boolean))
(define (any-decision? decision results)
  (ormap (lambda ([result : rule-result])
           (eq? decision (rule-result-decision result)))
         results))

(: all-decision? (-> RuleDecision (Listof rule-result) Boolean))
(define (all-decision? decision results)
  (andmap (lambda ([result : rule-result])
            (eq? decision (rule-result-decision result)))
          results))
