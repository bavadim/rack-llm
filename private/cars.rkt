#lang typed/racket/base

(require racket/list)

(provide TokenDomain CarsTrie CarsNode
         make-token-domain token-domain-member?
         make-cars-trie cars-trie-root cars-trie-node-count cars-trie-frozen?
         cars-node-mass cars-node-log-factor cars-node-child!
         cars-node-install-domain! cars-node-set-mass!)

(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))

;; only?=#t stores the allowed side; only?=#f stores its blocked complement.
(struct token-domain ([only? : Boolean] [ids : (Vectorof TokenId)]) #:transparent)
(define-type TokenDomain token-domain)

(struct cars-edge ([q : Real] [child : CarsNode]) #:transparent)
(struct cars-node
  ([envelope : Real]
   [domain : (Option TokenDomain)]
   [domain-mass : Real]
   [children : (HashTable TokenId cars-edge)]
   [parent : (Option CarsNode)])
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

(: make-token-domain (-> TokenIds Natural TokenDomain))
(define (make-token-domain allowed total-actions)
  (define allowed* (sort (remove-duplicates allowed) <))
  (if (<= (length allowed*) (quotient total-actions 2))
      (token-domain #t (list->vector allowed*))
      (token-domain
       #f
       (list->vector
        (let loop : TokenIds ([id : Natural 0] [rest : TokenIds allowed*])
         (cond
           [(>= id total-actions) '()]
           [(and (pair? rest) (= id (car rest)))
            (loop (add1 id) (cdr rest))]
           [else (cons id (loop (add1 id) rest))]))))))

(: token-domain-member? (-> TokenDomain TokenId Boolean))
(define (token-domain-member? domain id)
  (define ids (token-domain-ids domain))
  (define found?
    (let loop : Boolean ([lo : Integer 0] [hi : Integer (sub1 (vector-length ids))])
      (if (> lo hi)
          #f
          (let* ([mid (quotient (+ lo hi) 2)]
                 [candidate (vector-ref ids mid)])
            (cond [(= candidate id) #t]
                  [(< candidate id) (loop (add1 mid) hi)]
                  [else (loop lo (sub1 mid))])))))
  (if (token-domain-only? domain) found? (not found?)))

(: make-cars-trie (-> (Option Natural) CarsTrie))
(define (make-cars-trie max-nodes)
  (when (and max-nodes (zero? max-nodes))
    (raise-argument-error 'cars-sampler "positive max-trie-nodes or #f" max-nodes))
  (cars-trie (cars-node 1.0 #f 1.0 (make-hash) #f)
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

(: cars-node-log-factor (-> CarsNode TokenId Real))
(define (cars-node-log-factor node id)
  (define domain (cars-node-domain node))
  (cond
    [(and domain (not (token-domain-member? domain id))) -inf.0]
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
     (define child (cars-node 1.0 #f 1.0 (make-hash) node))
     (hash-set! (cars-node-children node) id (cars-edge q child))
     (set-box! (cars-trie-count-box trie) (add1 (trie-count trie)))
     child]))

(: cars-node-install-domain! (-> CarsNode TokenDomain Real Void))
(define (cars-node-install-domain! node domain mass)
  (unless (cars-node-domain node)
    (set-cars-node-domain! node domain)
    (set-cars-node-domain-mass! node (max 0.0 (min 1.0 mass)))
    (recompute-up! node)))

(: cars-node-set-mass! (-> CarsNode Real Void))
(define (cars-node-set-mass! node mass)
  (set-cars-node-envelope! node (max 0.0 (min 1.0 mass)))
  (define parent (cars-node-parent node))
  (when parent (recompute-up! parent)))

(: recompute-up! (-> CarsNode Void))
(define (recompute-up! node)
  (define domain (cars-node-domain node))
  (define base (if domain (cars-node-domain-mass node) 1.0))
  (define removed
    (for/fold ([total : Real 0.0]) ([(id edge) (in-hash (cars-node-children node))])
      (if (and domain (not (token-domain-member? domain id)))
          total
          (+ total (* (cars-edge-q edge)
                      (- 1.0 (cars-node-mass (cars-edge-child edge))))))))
  (define next (max 0.0 (min 1.0 (- base removed))))
  (unless (= next (cars-node-mass node))
    (set-cars-node-envelope! node next)
    (define parent (cars-node-parent node))
    (when parent (recompute-up! parent))))
