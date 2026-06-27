#lang typed/racket/base

(provide Agenda
         (struct-out agenda-item)
         agenda-empty
         agenda-push
         agenda-pop-max
         agenda-empty?
         agenda-size)

(struct agenda-item
  ([priority : Flonum]
   [payload : Any])
  #:transparent)

(struct agenda-entry
  ([item : agenda-item]
   [order : Natural])
  #:transparent)
(define-type HeapStorage (Mutable-Vectorof (Option agenda-entry)))

(struct list-agenda
  ([items : (Listof agenda-entry)]
   [next-order : Natural])
  #:transparent)

(struct heap-agenda
  ([items : HeapStorage]
   [size : Natural]
   [next-order : Natural])
  #:transparent)

(struct pairing-node
  ([entry : agenda-entry]
   [children : (Listof pairing-node)])
  #:transparent)
(define-type PairingNode pairing-node)

(struct pairing-heap-agenda
  ([root : (Option PairingNode)]
   [size : Natural]
   [next-order : Natural])
  #:transparent)

(define-type Agenda (U list-agenda heap-agenda pairing-heap-agenda))

(: agenda-empty (-> Symbol Agenda))
(define (agenda-empty kind)
  (case kind
    [(list) (list-agenda '() 0)]
    [(binary-heap) (heap-agenda (make-empty-storage 16) 0 0)]
    [(pairing-heap) (pairing-heap-agenda #f 0 0)]
    [else (error 'agenda-empty "unsupported agenda kind: ~a" kind)]))

(: agenda-push (-> Agenda agenda-item Agenda))
(define (agenda-push agenda item)
  (cond
    [(list-agenda? agenda)
     (list-agenda
      (insert-entry (agenda-entry item (list-agenda-next-order agenda))
                    (list-agenda-items agenda))
      (add1 (list-agenda-next-order agenda)))]
    [(heap-agenda? agenda)
     (heap-push agenda item)]
    [(pairing-heap-agenda? agenda)
     (pairing-push agenda item)]))

(: agenda-pop-max (-> Agenda (Values agenda-item Agenda)))
(define (agenda-pop-max agenda)
  (cond
    [(list-agenda? agenda)
     (define items (list-agenda-items agenda))
     (cond
       [(null? items) (error 'agenda-pop-max "empty agenda")]
       [else
        (values (agenda-entry-item (car items))
                (list-agenda (cdr items)
                             (list-agenda-next-order agenda)))])]
    [(heap-agenda? agenda)
     (heap-pop-max agenda)]
    [(pairing-heap-agenda? agenda)
     (pairing-pop-max agenda)]))

(: agenda-empty? (-> Agenda Boolean))
(define (agenda-empty? agenda)
  (cond
    [(list-agenda? agenda) (null? (list-agenda-items agenda))]
    [(heap-agenda? agenda) (zero? (heap-agenda-size agenda))]
    [(pairing-heap-agenda? agenda) (zero? (pairing-heap-agenda-size agenda))]))

(: agenda-size (-> Agenda Natural))
(define (agenda-size agenda)
  (cond
    [(list-agenda? agenda) (length (list-agenda-items agenda))]
    [(heap-agenda? agenda) (heap-agenda-size agenda)]
    [(pairing-heap-agenda? agenda) (pairing-heap-agenda-size agenda)]))

(: insert-entry (-> agenda-entry (Listof agenda-entry) (Listof agenda-entry)))
(define (insert-entry entry items)
  (cond
    [(null? items) (list entry)]
    [(entry-before? entry (car items)) (cons entry items)]
    [else (cons (car items) (insert-entry entry (cdr items)))]))

(: entry-before? (-> agenda-entry agenda-entry Boolean))
(define (entry-before? left right)
  (define left-item (agenda-entry-item left))
  (define right-item (agenda-entry-item right))
  (or (> (agenda-item-priority left-item)
         (agenda-item-priority right-item))
      (and (= (agenda-item-priority left-item)
              (agenda-item-priority right-item))
           (< (agenda-entry-order left)
              (agenda-entry-order right)))))

;; Binary heap implementation. The mutable vector is kept behind the Agenda API;
;; callers use the returned agenda value after each push/pop.

(: make-empty-storage (-> Natural HeapStorage))
(define (make-empty-storage capacity)
  (ann (make-vector capacity #f) HeapStorage))

(: heap-push (-> heap-agenda agenda-item heap-agenda))
(define (heap-push agenda item)
  (define size (heap-agenda-size agenda))
  (define storage (ensure-capacity (heap-agenda-items agenda) size))
  (define entry (agenda-entry item (heap-agenda-next-order agenda)))
  (vector-set! storage size entry)
  (heap-bubble-up! storage size)
  (heap-agenda storage (add1 size) (add1 (heap-agenda-next-order agenda))))

(: heap-pop-max (-> heap-agenda (Values agenda-item Agenda)))
(define (heap-pop-max agenda)
  (define size (heap-agenda-size agenda))
  (cond
    [(zero? size) (error 'agenda-pop-max "empty agenda")]
    [else
     (define storage (heap-agenda-items agenda))
     (define root (heap-ref storage 0))
     (define last-index (sub1 size))
     (define last-entry (heap-ref storage last-index))
     (vector-set! storage last-index #f)
     (cond
       [(zero? last-index) (void)]
       [else
        (vector-set! storage 0 last-entry)
        (heap-bubble-down! storage last-index 0)])
     (values (agenda-entry-item root)
             (heap-agenda storage last-index (heap-agenda-next-order agenda)))]))

(: ensure-capacity (-> HeapStorage Natural HeapStorage))
(define (ensure-capacity storage size)
  (cond
    [(< size (vector-length storage)) storage]
    [else
     (define next-capacity (max 1 (* 2 (vector-length storage))))
     (define next (make-empty-storage next-capacity))
     (copy-storage! storage next size)
     next]))

(: copy-storage! (-> HeapStorage HeapStorage Natural Void))
(define (copy-storage! source target size)
  (for ([i (in-range size)])
    (vector-set! target i (vector-ref source i))))

(: heap-ref (-> HeapStorage Natural agenda-entry))
(define (heap-ref storage index)
  (assert (vector-ref storage index) agenda-entry?))

(: heap-bubble-up! (-> HeapStorage Natural Void))
(define (heap-bubble-up! storage index)
  (cond
    [(zero? index) (void)]
    [else
     (define parent (quotient (sub1 index) 2))
     (cond
       [(entry-before? (heap-ref storage index)
                       (heap-ref storage parent))
        (heap-swap! storage index parent)
        (heap-bubble-up! storage parent)]
       [else (void)])]))

(: heap-bubble-down! (-> HeapStorage Natural Natural Void))
(define (heap-bubble-down! storage size index)
  (define left (+ (* 2 index) 1))
  (cond
    [(>= left size) (void)]
    [else
     (define right (add1 left))
     (define best-child
       (if (and (< right size)
                (entry-before? (heap-ref storage right)
                               (heap-ref storage left)))
           right
           left))
     (cond
       [(entry-before? (heap-ref storage best-child)
                       (heap-ref storage index))
        (heap-swap! storage index best-child)
        (heap-bubble-down! storage size best-child)]
       [else (void)])]))

(: heap-swap! (-> HeapStorage Natural Natural Void))
(define (heap-swap! storage left right)
  (define tmp (heap-ref storage left))
  (vector-set! storage left (heap-ref storage right))
  (vector-set! storage right tmp))

;; Pairing heap implementation.

(: pairing-push (-> pairing-heap-agenda agenda-item pairing-heap-agenda))
(define (pairing-push agenda item)
  (define entry (agenda-entry item (pairing-heap-agenda-next-order agenda)))
  (pairing-heap-agenda
   (pairing-merge (pairing-heap-agenda-root agenda)
                  (pairing-node entry '()))
   (add1 (pairing-heap-agenda-size agenda))
   (add1 (pairing-heap-agenda-next-order agenda))))

(: pairing-pop-max (-> pairing-heap-agenda (Values agenda-item Agenda)))
(define (pairing-pop-max agenda)
  (define root (pairing-heap-agenda-root agenda))
  (cond
    [(not root) (error 'agenda-pop-max "empty agenda")]
    [else
     (values (agenda-entry-item (pairing-node-entry root))
             (pairing-heap-agenda
              (pairing-merge-pairs (pairing-node-children root))
              (assert (sub1 (pairing-heap-agenda-size agenda))
                      exact-nonnegative-integer?)
              (pairing-heap-agenda-next-order agenda)))]))

(: pairing-merge (-> (Option PairingNode) PairingNode PairingNode))
(define (pairing-merge maybe-left right)
  (cond
    [(not maybe-left) right]
    [else
     (if (entry-before? (pairing-node-entry maybe-left)
                        (pairing-node-entry right))
         (pairing-node (pairing-node-entry maybe-left)
                       (cons right (pairing-node-children maybe-left)))
         (pairing-node (pairing-node-entry right)
                       (cons maybe-left (pairing-node-children right))))]))

(: pairing-merge-two (-> PairingNode PairingNode PairingNode))
(define (pairing-merge-two left right)
  (pairing-merge left right))

(: pairing-merge-pairs (-> (Listof PairingNode) (Option PairingNode)))
(define (pairing-merge-pairs children)
  (cond
    [(null? children) #f]
    [(null? (cdr children)) (car children)]
    [else
     (pairing-merge
      (pairing-merge-pairs (cddr children))
      (pairing-merge-two (car children) (cadr children)))]))
