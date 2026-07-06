#lang racket/base

(require json
         racket/cmdline
         rack-llm
         rack-llm/llama-cpp)

(define model-path (make-parameter "/mnt/storage/models/qwen/Qwen3.5-4B"))
(define sidecar-command
  (make-parameter
   ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/hf_logits_sidecar.py --model-path /mnt/storage/models/qwen/Qwen3.5-4B"))
(define output-path (make-parameter #f))

(command-line
 #:program "racket_sidecar_smoke.rkt"
 #:once-each
 [("--model-path") path "Hugging Face model directory"
                   (model-path path)]
 [("--sidecar-command") command "Command used by make-llama-cpp-provider"
                        (sidecar-command command)]
 [("--output") path "Write JSON smoke result to path"
               (output-path path)])

(define started-ms (current-inexact-milliseconds))
(define p
  (make-llama-cpp-provider
   #:model-path (model-path)
   #:command (sidecar-command)
   #:context-size 128
   #:threads 1
   #:seed 0))

(define prompt "Say one word.")
(define ids (tokenize p prompt))
(define roundtrip (detokenize p ids))
(define generated
  (generate p prompt (select (lit " yes") (lit " no"))
            #:seed 0
            #:temperature 0.7
            #:max-tokens 2))

(define payload
  (hash 'ok #t
        'model_path (model-path)
        'roundtrip_ok (string=? prompt roundtrip)
        'token_count (length ids)
        'generation_status (symbol->string (generation-result-status generated))
        'generated_text (generation-result-text generated)
        'generated_tokens (generation-result-generated-tokens generated)
        'latency_ms (- (current-inexact-milliseconds) started-ms)))

(define (write-payload out)
  (write-json payload out)
  (newline out))

(cond
  [(output-path)
   (call-with-output-file (output-path)
     write-payload
     #:exists 'replace)]
  [else
   (write-payload (current-output-port))])
