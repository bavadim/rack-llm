#lang typed/racket/base
(require racket/list)
(provide TokenDomain domain-all domain-none domain-only domain-only/vector
         domain-include? domain-ids domain-member? domain-union domain-force-membership)
(define-type TokenId Natural)
(struct token-domain ([include? : Boolean] [ids : (Vectorof TokenId)]) #:transparent)
(define-type TokenDomain token-domain)
(define domain-all (token-domain #f (vector-immutable)))
(define domain-none (token-domain #t (vector-immutable)))
(: sorted (-> (Listof TokenId) (Vectorof TokenId)))
(define (sorted xs) (list->vector (sort (remove-duplicates xs) <)))
(: domain-only (-> (Listof TokenId) TokenDomain))
(define (domain-only xs) (token-domain #t (sorted xs)))
(: domain-only/vector (-> (Vectorof TokenId) TokenDomain))
(define (domain-only/vector xs) (token-domain #t xs))
(: domain-include? (-> TokenDomain Boolean))
(define domain-include? token-domain-include?)
(: domain-ids (-> TokenDomain (Vectorof TokenId)))
(define domain-ids token-domain-ids)
(: domain-member? (-> TokenDomain TokenId Boolean))
(define (domain-member? d id)
  (define found? : Boolean
    (let loop : Boolean ([lo : Integer 0] [hi : Integer (sub1 (vector-length (domain-ids d)))])
      (and (<= lo hi)
           (let* ([mid (quotient (+ lo hi) 2)] [x (vector-ref (domain-ids d) mid)])
             (cond [(= x id) #t] [(< x id) (loop (add1 mid) hi)]
                   [else (loop lo (sub1 mid))])))))
  (if (domain-include? d) found? (not found?)))
;; Sorted set operation: union, intersection, or a-b.
(: set-op (-> (Vectorof TokenId) (Vectorof TokenId) Symbol (Vectorof TokenId)))
(define (set-op a b op)
  (list->vector
   (let loop : (Listof TokenId) ([i : Natural 0] [j : Natural 0])
     (cond [(and (= i (vector-length a)) (= j (vector-length b))) '()]
           [else
            (define av (and (< i (vector-length a)) (vector-ref a i)))
            (define bv (and (< j (vector-length b)) (vector-ref b j)))
            (define left? (and av (or (not bv) (< av bv))))
            (define right? (and bv (or (not av) (< bv av))))
            (define same? (and av bv (= av bv)))
            (define keep? (case op [(union) #t] [(intersection) same?] [(difference) left?]))
            (define value (cond [left? av] [right? bv] [else av]))
            (define rest (loop (if (or left? same?) (add1 i) i)
                               (if (or right? same?) (add1 j) j)))
            (if (and keep? value) (cons value rest) rest)]))))
(: domain-union (-> TokenDomain TokenDomain TokenDomain))
(define (domain-union a b)
  (cond [(eq? a domain-none) b] [(eq? b domain-none) a]
        [(or (eq? a domain-all) (eq? b domain-all)) domain-all]
        [(and (domain-include? a) (domain-include? b))
         (token-domain #t (set-op (domain-ids a) (domain-ids b) 'union))]
        [(and (not (domain-include? a)) (not (domain-include? b)))
         (token-domain #f (set-op (domain-ids a) (domain-ids b) 'intersection))]
        [(domain-include? a)
         (token-domain #f (set-op (domain-ids b) (domain-ids a) 'difference))]
        [else (token-domain #f (set-op (domain-ids a) (domain-ids b) 'difference))]))
(: domain-force-membership (-> TokenDomain (Listof TokenId) Boolean TokenDomain))
(define (domain-force-membership d xs allowed?)
  (define b (sorted xs))
  (cond [(null? xs) d]
        [(domain-include? d)
         (token-domain #t (set-op (domain-ids d) b (if allowed? 'union 'difference)))]
        [else (token-domain #f (set-op (domain-ids d) b (if allowed? 'difference 'union)))]))
