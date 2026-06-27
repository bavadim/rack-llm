#lang typed/racket/base

(require typed/racket/stream
         "common-combinators.rkt"
         "grammar.rkt"
         "sampling/agenda.rkt")

(require/typed racket/list
  [filter-map (All (A B) (-> (-> A (U B False)) (Listof A) (Listof B)))])

(provide decode-body)

(define-type GumbelScore Flonum)

(struct frontier-node
  ([depth : TokenBudget]
   [logp : LogProb]
   [g : GumbelScore]
   [state : MatcherState])
  #:transparent)
(define-type FrontierNode frontier-node)
(define-type FrontierAgenda Agenda)

(: decode-body (-> TokenOracle EvaluatedProgram Grammar EvaluatedBodyStream))
(define (decode-body oracle transcript target)
  (define matcher (compile-matcher target))
  (gumbel-stream
   (frontier-expander oracle transcript (search-budget target))
   (frontier-root matcher)))

(: gumbel-stream (-> (-> FrontierNode (Listof FrontierNode)) FrontierNode EvaluatedBodyStream))
(define (gumbel-stream expand root)
  (: step (-> FrontierAgenda EvaluatedBodyStream))
  (define (step queue)
    (define next (frontier-agenda-pop queue))
    (cond
      [(not next) empty-stream]
      [else
       (define current (frontier-agenda-view-item next))
       (define rest (frontier-agenda-view-rest next))
       (stream-append-lazy
        (frontier-yields current)
        (lambda ()
          (step (frontier-agenda-push* rest (frontier-successors expand current)))))]))
  (step (frontier-agenda-singleton root)))

(: frontier-expander (-> TokenOracle EvaluatedProgram TokenBudget (-> FrontierNode (Listof FrontierNode))))
(define (frontier-expander oracle transcript max-depth)
  (lambda ([parent : FrontierNode])
    (if (>= (frontier-node-depth parent) max-depth)
        '()
        (condition-subtrees
         parent
         (filter-map (lambda ([c : token-candidate])
                       (frontier-child parent c))
                     (oracle transcript (frontier-text parent)))))))

;; Frontier algebra

(: frontier-root (-> Matcher FrontierNode))
(define (frontier-root matcher)
  (frontier-node 0 0.0 (gumbel) (matcher-start matcher)))

(: frontier-child (-> FrontierNode token-candidate (U FrontierNode False)))
(define (frontier-child parent candidate)
  (and (valid-candidate? candidate)
       (let ([logp (+ (frontier-node-logp parent)
                      (token-candidate-logp candidate))])
         (frontier-node (add1 (frontier-node-depth parent))
                        logp
                        (+ logp (gumbel))
                        (matcher-advance (frontier-node-state parent)
                                         (token-candidate-text candidate))))))

(: condition-subtrees (-> FrontierNode (Listof FrontierNode) (Listof FrontierNode)))
(define (condition-subtrees parent children)
  (cond
    [(null? children) '()]
    [else
     (define raw-max (apply max (map frontier-node-g children)))
     (map (lambda ([child : FrontierNode])
            (condition-subtree parent raw-max child))
          children)]))

(: condition-subtree (-> FrontierNode GumbelScore FrontierNode FrontierNode))
(define (condition-subtree parent raw-max child)
  (struct-copy frontier-node child
               [g (cond-gumbel (frontier-node-g parent)
                               (frontier-node-g child)
                               raw-max)]))

(: frontier-yields (-> FrontierNode (Listof EvaluatedBody)))
(define (frontier-yields n)
  (matcher-yields (frontier-node-state n)))

(: frontier-successors (-> (-> FrontierNode (Listof FrontierNode)) FrontierNode (Listof FrontierNode)))
(define (frontier-successors expand n)
  (filter frontier-viable? (expand n)))

(: frontier-text (-> FrontierNode String))
(define (frontier-text n)
  (matcher-text (frontier-node-state n)))

(: frontier-viable? (-> FrontierNode Boolean))
(define (frontier-viable? n)
  (matcher-viable? (frontier-node-state n)))

(: valid-candidate? (-> token-candidate Boolean))
(define (valid-candidate? candidate)
  (> (token-candidate-logp candidate) -1e300))

(: search-budget (-> Grammar TokenBudget))
(define (search-budget target)
  (max 8 (+ 16 (target-token-budget target))))

;; Frontier agenda adapter

(struct frontier-agenda-view
  ([item : FrontierNode]
   [rest : FrontierAgenda])
  #:transparent)

(: frontier-agenda-singleton (-> FrontierNode FrontierAgenda))
(define (frontier-agenda-singleton item)
  (agenda-push (agenda-empty 'binary-heap) (frontier->agenda-item item)))

(: frontier-agenda-pop (-> FrontierAgenda (U False frontier-agenda-view)))
(define (frontier-agenda-pop queue)
  (cond
    [(agenda-empty? queue) #f]
    [else
     (define-values (item rest) (agenda-pop-max queue))
     (frontier-agenda-view
      (assert (agenda-item-payload item) frontier-node?)
      rest)]))

(: frontier-agenda-push* (-> FrontierAgenda (Listof FrontierNode) FrontierAgenda))
(define (frontier-agenda-push* queue items)
  (foldl (lambda ([item : FrontierNode] [acc : FrontierAgenda])
           (agenda-push acc (frontier->agenda-item item)))
         queue
         items))

(: frontier->agenda-item (-> FrontierNode agenda-item))
(define (frontier->agenda-item n)
  (agenda-item (frontier-node-g n) n))

;; Gumbel noise

(: ->fl (-> Number Flonum))
(define (->fl x)
  (real->double-flonum (real-part x)))

(: gumbel (-> GumbelScore))
(define (gumbel)
  (define u (max 1e-12 (min (- 1.0 1e-12) (random))))
  (->fl (- (log (- (log u))))))

(: cond-gumbel (-> GumbelScore GumbelScore GumbelScore GumbelScore))
(define (cond-gumbel parent-g raw-child-g raw-max)
  (define mass
    (+ (- (exp (- parent-g))
          (exp (- raw-max)))
       (exp (- raw-child-g))))
  (->fl (- (log (max 1e-300 (real-part mass))))))
