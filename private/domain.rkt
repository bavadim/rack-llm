#lang typed/racket/base

(require racket/list)

(provide TokenDomain domain-all domain-none domain-only domain-except
         domain-include? domain-ids domain-member?
         domain-union domain-subtract)

(define-type TokenId Natural)

;; include? means ids are the allowed set; otherwise ids are its complement.
(struct token-domain ([include? : Boolean] [ids : (Vectorof TokenId)]) #:transparent)
(define-type TokenDomain token-domain)

(define domain-all (token-domain #f (vector-immutable)))
(define domain-none (token-domain #t (vector-immutable)))

(: sorted-unique (-> (Listof TokenId) (Vectorof TokenId)))
(define (sorted-unique ids)
  (ann (list->vector (sort (remove-duplicates ids) <)) (Vectorof TokenId)))

(: domain-only (-> (Listof TokenId) TokenDomain))
(define (domain-only ids) (token-domain #t (sorted-unique ids)))
(: domain-except (-> (Listof TokenId) TokenDomain))
(define (domain-except ids) (token-domain #f (sorted-unique ids)))
(: domain-include? (-> TokenDomain Boolean))
(define (domain-include? d) (token-domain-include? d))
(: domain-ids (-> TokenDomain (Vectorof TokenId)))
(define (domain-ids d) (token-domain-ids d))

(: member/vector? (-> (Vectorof TokenId) TokenId Boolean))
(define (member/vector? ids id)
  (let loop ([lo : Integer 0] [hi : Integer (sub1 (vector-length ids))])
    (and (<= lo hi)
         (let* ([mid (quotient (+ lo hi) 2)] [x (vector-ref ids mid)])
           (cond [(= x id) #t]
                 [(< x id) (loop (add1 mid) hi)]
                 [else (loop lo (sub1 mid))])))))

(: domain-member? (-> TokenDomain TokenId Boolean))
(define (domain-member? d id)
  (if (token-domain-include? d)
      (member/vector? (token-domain-ids d) id)
      (not (member/vector? (token-domain-ids d) id))))

(: merge (-> (Vectorof TokenId) (Vectorof TokenId) Symbol (Vectorof TokenId)))
(define (merge a b op)
  (ann
   (list->vector
    (let loop : (Listof TokenId) ([i : Natural 0] [j : Natural 0])
      (cond
        [(and (= i (vector-length a)) (= j (vector-length b))) '()]
        [else
         (define av : (Option TokenId) (and (< i (vector-length a)) (vector-ref a i)))
         (define bv : (Option TokenId) (and (< j (vector-length b)) (vector-ref b j)))
         (define take-a? (and av (or (not bv) (< av bv))))
         (define take-b? (and bv (or (not av) (< bv av))))
         (define same? (and av bv (= av bv)))
         (define keep?
           (case op
             [(union) (or take-a? take-b? same?)]
             [(intersection) same?]
             [(difference) take-a?]
             [else #f]))
         (define value (cond [take-a? av] [take-b? bv] [else av]))
         (define next-i (if (or take-a? same?) (add1 i) i))
         (define next-j (if (or take-b? same?) (add1 j) j))
         (define rest (loop next-i next-j))
         (if (and keep? value) (cons value rest) rest)])))
   (Vectorof TokenId)))

(: make-domain (-> Boolean (Vectorof TokenId) TokenDomain))
(define (make-domain include? ids) (token-domain include? ids))

(: domain-union (-> TokenDomain TokenDomain TokenDomain))
(define (domain-union left right)
  (define a (domain-ids left))
  (define b (domain-ids right))
  (cond
    [(and (domain-include? left) (domain-include? right))
     (make-domain #t (merge a b 'union))]
    [(and (not (domain-include? left)) (not (domain-include? right)))
     (make-domain #f (merge a b 'intersection))]
    [(domain-include? left) (make-domain #f (merge b a 'difference))]
    [else (make-domain #f (merge a b 'difference))]))

(: domain-subtract (-> TokenDomain TokenDomain TokenDomain))
(define (domain-subtract left right)
  (define a (domain-ids left))
  (define b (domain-ids right))
  (cond
    [(and (domain-include? left) (domain-include? right))
     (make-domain #t (merge a b 'difference))]
    [(and (domain-include? left) (not (domain-include? right)))
     (make-domain #t (merge a b 'intersection))]
    [(and (not (domain-include? left)) (domain-include? right))
     (make-domain #f (merge a b 'union))]
    [else (make-domain #t (merge b a 'difference))]))
