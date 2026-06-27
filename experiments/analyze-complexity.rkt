#lang racket/base

(require racket/cmdline
         rack-llm/experiments/complexity)

(define out-path #f)

(define trace-paths
  (command-line
   #:program "analyze-complexity"
   #:once-each
   [("--out") path "Write complexity CSV to path"
    (set! out-path path)]
   #:args paths
   paths))

(unless out-path
  (error 'analyze-complexity "missing required --out path"))

(when (null? trace-paths)
  (error 'analyze-complexity "expected at least one trace JSONL path"))

(define records
  (apply append (map read-complexity-records-from-file trace-paths)))

(call-with-output-file out-path
  (lambda (out)
    (write-complexity-csv out (summarize-complexity records)))
  #:exists 'replace)
