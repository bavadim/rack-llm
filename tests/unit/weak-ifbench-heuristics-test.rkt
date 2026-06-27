#lang racket/base

(require racket/runtime-path
         rackunit
         rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/heuristics
         rack-llm/rules/combinators
         rack-llm/rules/rule)

(define-runtime-path fixture "../fixtures/weak-ifbench-small.jsonl")

(define weak-ifbench-heuristics-tests
  (test-suite
   "Weak-IFBench heuristic templates"

   (test-case "word count rules accept reject and abstain"
     (define split-rule
       (find-rule 'word-count/split
                  (weak-rules-for-constraint
                   (constraint-spec 'word-count 'word-count (hash 'count 10)))))
     (check-equal? (decision split-rule "one two") 'reject)
     (check-equal? (decision split-rule "one two three four five six seven eight nine ten")
                   'accept)
     (check-equal? (decision split-rule "```code block```") 'abstain))

   (test-case "forbidden phrase rules reject dirty and accept clean text"
     (define forbidden-rule
       (find-rule 'forbidden-phrase/lowercase
                  (weak-rules-for-constraint
                   (constraint-spec 'forbidden-phrase
                                    'forbidden-phrase
                                    (hash 'phrase "bad word")))))
     (check-equal? (decision forbidden-rule "no bad word here") 'reject)
     (check-equal? (decision forbidden-rule "clean text") 'accept))

   (test-case "supported groups produce at least two weak rules"
     (for ([constraint (in-list supported-constraints)])
       (check-true (supported-constraint-type? (constraint-spec-type constraint)))
       (check-true (>= (length (weak-rules-for-constraint constraint)) 2))))

   (test-case "fixture task produces non-empty rules and explicit coverage"
     (define task (car (load-ifbench-jsonl fixture)))
     (check-true (not (null? (weak-rules-for-task task))))
     (define coverage
       (weak-rule-coverage-for-task
        (ifbench-task "mixed"
                      "prompt"
                      (append (ifbench-task-constraints task)
                              (list (constraint-spec 'unknown 'not-supported (hash))))
                      'embedded
                      (hash))))
     (check-equal? (length (weak-rule-coverage-supported coverage)) 2)
     (check-equal? (map constraint-spec-id
                        (weak-rule-coverage-unsupported coverage))
                   '(unknown)))

   (test-case "JSON and Markdown structure rules are weak local checks"
     (define json-rules
       (weak-rules-for-constraint
        (constraint-spec 'json-structure 'json-structure (hash 'root 'object))))
     (check-equal? (decision (find-rule 'json/parse json-rules) "{\"ok\": true}")
                   'accept)
     (check-equal? (decision (find-rule 'json/braces json-rules) "not json")
                   'reject)
     (define markdown-rules
       (weak-rules-for-constraint
        (constraint-spec 'markdown-structure 'markdown-structure (hash))))
     (check-equal? (decision (find-rule 'markdown/headings markdown-rules) "# Title\nBody")
                   'accept)
     (check-equal? (decision (find-rule 'markdown/list-or-code markdown-rules) "plain")
                   'reject))))

(define supported-constraints
  (list (constraint-spec 'word-count 'word-count (hash 'count 3))
        (constraint-spec 'sentence-count 'sentence-count (hash 'min 1))
        (constraint-spec 'phrase-presence 'phrase-presence (hash 'phrase "x"))
        (constraint-spec 'forbidden-phrase 'forbidden-phrase (hash 'phrase "x"))
        (constraint-spec 'section-header 'section-header (hash 'header "Result"))
        (constraint-spec 'json-structure 'json-structure (hash 'root 'object))
        (constraint-spec 'markdown-structure 'markdown-structure (hash))))

(define (find-rule id weighted-rules)
  (define found
    (findf (lambda (wr)
             (eq? (rule-id (weighted-rule-rule wr)) id))
           weighted-rules))
  (unless found
    (error 'find-rule "missing rule ~a" id))
  (weighted-rule-rule found))

(define (decision r candidate)
  (rule-result-decision (apply-rule r candidate)))

(module+ test
  (require rackunit/text-ui)
  (run-tests weak-ifbench-heuristics-tests))
