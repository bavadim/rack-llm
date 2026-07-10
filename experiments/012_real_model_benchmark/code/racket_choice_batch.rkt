#lang racket/base

(require json
         racket/cmdline
         rack-llm
         rack-llm/model-llama-cpp)

(define default-gguf-model-path
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define model-path (make-parameter (or (getenv "RACK_LLM_GGUF_MODEL") default-gguf-model-path)))
(define input-path (make-parameter #f))
(define output-path (make-parameter #f))

(command-line
 #:program "racket_choice_batch.rkt"
 #:once-each
 [("--model-path") path "GGUF model file"
                   (model-path path)]
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

(define model
  (llama-cpp-model
   #:model-path (model-path)
   #:context-size 512
   #:threads 1
   #:gpu-layers -1))

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
     (choice
      (for/list ([item (in-list choices)])
        (lit item)))]
    [(string? regex) (rx regex)]
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
      (generate model
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
          'outcome (if (eq? (generation-result-status generated) 'found) "GENERATED" "NOT_FOUND")
          'failure_reason (or (generation-result-reason generated) "")
          'source "real_runtime")))

(call-with-output-file (output-path)
  (lambda (out)
    (for ([request (in-list requests)])
      (write-json (run-one request) out)
      (newline out)
      (flush-output out)))
  #:exists 'replace)

(model-close! model)
