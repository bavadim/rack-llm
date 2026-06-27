#lang racket

(require rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/methods
         rack-llm/rules)

(define task
  (ifbench-task
   "mini"
   "Include the phrase approved."
   (list (constraint-spec 'phrase
                          'phrase-presence
                          (hash 'phrase "approved")))
   'embedded
   (hash 'fake_gold_substring "approved"
         'fake_constraint_substrings (hash 'phrase "approved"))))

(define candidates
  (list (candidate 1 "missing phrase" 0.1 (hash))
        (candidate 2 "approved answer" 0.2 (hash))))

(define ctx
  (experiment-context
   (lambda (_task budget)
     (let loop ([remaining candidates] [n budget] [acc '()])
       (cond
         [(or (zero? n) (null? remaining)) (reverse acc)]
         [else (loop (cdr remaining) (sub1 n) (cons (car remaining) acc))])))
   #f
   (acceptance-config 'all-constraints 0.5 (hash) (hash))))

(define result
  (run-method 'independent-majority ctx task 2))

(displayln (candidate-text (method-result-selected result)))
