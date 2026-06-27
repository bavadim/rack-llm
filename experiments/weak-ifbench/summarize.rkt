#lang racket/base

(require racket/cmdline
         rack-llm/experiments/weak-ifbench/artifacts)

(define out-dir #f)

(define run-dirs
  (command-line
   #:program "weak-ifbench-summarize"
   #:once-each
   [("--out") path "Output table directory"
    (set! out-dir path)]
   #:args dirs
   dirs))

(unless out-dir
  (error 'weak-ifbench-summarize "missing required --out"))

(unless (= (length run-dirs) 1)
  (error 'weak-ifbench-summarize "expected exactly one run directory"))

(generate-artifacts (car run-dirs) out-dir)
