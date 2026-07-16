#lang typed/racket/base

(require (only-in "domain.rkt" TokenDomain domain-member?))

(provide CarsTrie CarsNode
         make-cars-trie cars-trie-root cars-trie-node-count cars-trie-frozen?
         cars-node-mass cars-node-domain-value cars-node-child-masses
         cars-node-log-factor cars-node-child!
         cars-node-install-domain! cars-node-set-mass!)

(define-type TokenId Natural)
(struct cars-edge ([q : Real] [child : CarsNode]) #:transparent)
(struct cars-node
  ([envelope : Real]
   [domain : (Option TokenDomain)]
   [domain-mass : Real]
   [children : (HashTable TokenId cars-edge)]
   [parent : (Option CarsNode)]
   [incoming-id : TokenId]
   [incoming-q : Real])
  #:mutable
  #:transparent)
(define-type CarsNode cars-node)

(struct cars-trie
  ([root : CarsNode]
   [count-box : (Boxof Natural)]
   [max-nodes : (Option Natural)]
   [frozen-box : (Boxof Boolean)])
  #:transparent)
(define-type CarsTrie cars-trie)

(: make-cars-trie (-> (Option Natural) CarsTrie))
(define (make-cars-trie max-nodes)
  (when (and max-nodes (zero? max-nodes))
    (raise-argument-error 'cars-sampler "positive max-trie-nodes or #f" max-nodes))
  (cars-trie (cars-node 1.0 #f 1.0 (make-hash) #f 0 0.0)
             (box 1)
             max-nodes
             (box #f)))

(: cars-trie-node-count (-> CarsTrie Natural))
(define (cars-trie-node-count trie) (unbox (cars-trie-count-box trie)))

;; Keep the struct accessor available internally under an unambiguous name.
(: trie-count (-> CarsTrie Natural))
(define (trie-count trie) (unbox (cars-trie-count-box trie)))

(: cars-trie-frozen? (-> CarsTrie Boolean))
(define (cars-trie-frozen? trie) (unbox (cars-trie-frozen-box trie)))

(: cars-node-mass (-> CarsNode Real))
(define (cars-node-mass node) (cars-node-envelope node))

(: cars-node-domain-value (-> CarsNode (Option TokenDomain)))
(define (cars-node-domain-value node) (cars-node-domain node))

(: cars-node-child-masses (-> CarsNode (Listof (Pairof TokenId Real))))
(define (cars-node-child-masses node)
  (sort
   (for/list : (Listof (Pairof TokenId Real))
             ([(id edge) (in-hash (cars-node-children node))]
              #:unless (= (cars-node-mass (cars-edge-child edge)) 1.0))
     (cons id (cars-node-mass (cars-edge-child edge))))
   (lambda ([left : (Pairof TokenId Real)] [right : (Pairof TokenId Real)])
     (< (car left) (car right)))))

(: cars-node-log-factor (-> CarsNode TokenId Real))
(define (cars-node-log-factor node id)
  (define domain (cars-node-domain node))
  (cond
    [(and domain (not (domain-member? domain id))) -inf.0]
    [else
     (define edge (hash-ref (cars-node-children node) id #f))
     (if edge
         (let ([mass (cars-node-mass (cars-edge-child edge))])
           (if (<= mass 0.0) -inf.0 (assert (log mass) real?)))
         0.0)]))

(: cars-node-child! (-> CarsTrie CarsNode TokenId Real (Option CarsNode)))
(define (cars-node-child! trie node id q)
  (define old (hash-ref (cars-node-children node) id #f))
  (cond
    [old (cars-edge-child old)]
    [(and (cars-trie-max-nodes trie)
          (>= (trie-count trie) (assert (cars-trie-max-nodes trie) exact-nonnegative-integer?)))
     (set-box! (cars-trie-frozen-box trie) #t)
     #f]
    [else
     (define child (cars-node 1.0 #f 1.0 (make-hash) node id q))
     (hash-set! (cars-node-children node) id (cars-edge q child))
     (set-box! (cars-trie-count-box trie) (add1 (trie-count trie)))
     child]))

(: cars-node-install-domain! (-> CarsNode TokenDomain Real Void))
(define (cars-node-install-domain! node domain mass)
  (unless (cars-node-domain node)
    (set-cars-node-domain! node domain)
    (set-cars-node-domain-mass! node (max 0.0 (min 1.0 mass)))
    (define removed
      (for/fold ([total : Real 0.0]) ([(id edge) (in-hash (cars-node-children node))])
        (if (domain-member? domain id)
            (+ total (* (cars-edge-q edge)
                        (- 1.0 (cars-node-mass (cars-edge-child edge)))))
            total)))
    (set-mass/propagate! node (- (cars-node-domain-mass node) removed))))

(: cars-node-set-mass! (-> CarsNode Real Void))
(define (cars-node-set-mass! node mass)
  (set-mass/propagate! node mass))

(: set-mass/propagate! (-> CarsNode Real Void))
(define (set-mass/propagate! node raw)
  (define next (max 0.0 (min 1.0 raw)))
  (define delta (- next (cars-node-mass node)))
  (unless (zero? delta)
    (set-cars-node-envelope! node next)
    (define parent (cars-node-parent node))
    (when (and parent
               (let ([domain (cars-node-domain parent)])
                 (or (not domain) (domain-member? domain (cars-node-incoming-id node)))))
      (set-mass/propagate! parent
                           (+ (cars-node-mass parent)
                              (* (cars-node-incoming-q node) delta))))))
