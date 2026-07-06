#lang racket/base

(require json
         racket/cmdline
         rack-llm
         rack-llm/llama-cpp)

(define model-path (make-parameter "/mnt/storage/models/qwen/Qwen3.5-4B"))
(define sidecar-command
  (make-parameter
   ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/hf_logits_sidecar.py --model-path /mnt/storage/models/qwen/Qwen3.5-4B"))
(define input-path (make-parameter #f))
(define output-path (make-parameter #f))

(command-line
 #:program "racket_choice_batch.rkt"
 #:once-each
 [("--model-path") path "Hugging Face model directory"
                   (model-path path)]
 [("--sidecar-command") command "Command used by make-llama-cpp-provider"
                        (sidecar-command command)]
 [("--input") path "JSON file containing choice-generation requests"
              (input-path path)]
 [("--output") path "Write JSONL generation rows to path"
               (output-path path)])

(unless (input-path)
  (error 'racket_choice_batch "missing --input"))
(unless (output-path)
  (error 'racket_choice_batch "missing --output"))

(define requests
  (call-with-input-file (input-path) read-json))

(define p
  (make-llama-cpp-provider
   #:model-path (model-path)
   #:command (sidecar-command)
   #:context-size 512
   #:threads 1
   #:seed 0))

(define (field row key [default (lambda () (error 'field "missing key ~a in ~s" key row))])
  (hash-ref row key
            (lambda ()
              (hash-ref row (symbol->string key)
                        (lambda ()
                          (if (procedure? default) (default) default))))))

(define (request->guide request)
  (define choices (field request 'choices #f))
  (define regex (field request 'regex #f))
  (cond
    [(and (list? choices) (pair? choices))
     (apply select
            (for/list ([choice (in-list choices)])
              (lit choice)))]
    [(string? regex) (rx (pregexp regex))]
    [else (error 'racket_choice_batch
                 "request must contain non-empty choices or regex: ~s"
                 request)]))

(define (run-one request)
  (define started-ms (current-inexact-milliseconds))
  (with-handlers
    ([exn:fail?
      (lambda (exn)
        (hash 'run_id (field request 'run_id)
              'key (field request 'key)
              'method "ours_hard"
              'seed (field request 'seed)
              'text ""
              'latency_ms (- (current-inexact-milliseconds) started-ms)
              'generated_tokens 0
              'outcome "ERROR"
              'failure_reason (exn-message exn)
              'source "real_runtime"))])
    (define generated
      (generate p
                (field request 'prompt)
                (request->guide request)
                #:seed (field request 'seed)
                #:temperature 0.7
                #:max-tokens (field request 'max_tokens 512)))
    (hash 'run_id (field request 'run_id)
          'key (field request 'key)
          'method "ours_hard"
          'seed (field request 'seed)
          'text (generation-result-text generated)
          'latency_ms (- (current-inexact-milliseconds) started-ms)
          'generated_tokens (generation-result-generated-tokens generated)
          'outcome (if (generation-result-ok? generated) "GENERATED" "NOT_FOUND")
          'failure_reason (or (generation-result-reason generated) "")
          'source "real_runtime")))

(call-with-output-file (output-path)
  (lambda (out)
    (for ([request (in-list requests)])
      (write-json (run-one request) out)
      (newline out)
      (flush-output out)))
  #:exists 'replace)
