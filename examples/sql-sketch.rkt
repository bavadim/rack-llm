#lang racket

(require rack-llm)

;; This file is intentionally a sketch: real schema objects can be structs,
;; database metadata records, or anything else. `pick` returns the original
;; Racket value, while #:show controls what the model sees.

(struct metric (name sql) #:transparent)
(struct table (name columns) #:transparent)

(define metrics
  (list (metric "revenue" "sum(amount)")
        (metric "orders_count" "count(*)")))

(define tables
  (list (table "orders" '("created_at" "amount" "customer_id"))))

(define-grammar (sql-g ctx)
  (emit "SELECT ")
  (define m
    (pick metrics #:as 'metric #:show metric-name))
  (emit (metric-sql m))
  (emit " FROM ")
  (define t
    (pick tables #:as 'table #:show table-name))
  (emit (table-name t))
  (emit " WHERE created_at >= ")
  (select '("'2026-01-01'" "'2026-04-01'" "'2026-05-01'")
          #:as 'date-from))

(define (metric-matches-intent ctx cand)
  (define m (candidate-ref cand 'metric))
  (if (and (regexp-match? #px"выруч|revenue" (hash-ref ctx 'question ""))
           (not (equal? (metric-name m) "revenue")))
      (fail "metric does not match revenue intent"
            #:hint "Для вопроса про выручку выбери revenue.")
      (pass #:score 0.8)))

;; Usage with a real model:
;;
;; (run model
;;      (chat
;;       (system "You produce SQL snippets.")
;;       (user "Покажи выручку с апреля 2026")
;;       (assistant
;;        (best-of (sql-g ctx)
;;                 #:as 'sql
;;                 #:tries 8
;;                 #:context (hash 'question "Покажи выручку с апреля 2026")
;;                 #:reviewers (list (weighted 3 metric-matches-intent))))))
