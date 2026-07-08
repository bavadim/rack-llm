#lang racket/base

(require json
         racket/cmdline
         racket/runtime-path
         rack-llm
         rack-llm/llama-cpp)

(define-runtime-path repo-root "../../..")

(define model-path (make-parameter "/mnt/storage/models/qwen/Qwen3.5-4B"))
(define sidecar-command
  (make-parameter
   (format "~a ~a --model-path /mnt/storage/models/qwen/Qwen3.5-4B"
           (path->string (build-path repo-root ".venv-realbench" "bin" "python"))
           (path->string (build-path repo-root "experiments" "012_real_model_benchmark" "code" "hf_logits_sidecar.py")))))
(define output-path (make-parameter #f))

(command-line
 #:program "racket_sidecar_smoke.rkt"
 #:once-each
 [("--model-path") path "Hugging Face model directory"
                   (model-path path)]
 [("--sidecar-command") command "Command used by make-llama-cpp-backend"
                        (sidecar-command command)]
 [("--output") path "Write JSON smoke result to path"
               (output-path path)])

(define backend #f)

(define (write-payload payload out)
  (write-json payload out)
  (newline out))

(dynamic-wind
  (lambda ()
    (set! backend
          (make-llama-cpp-backend
           #:model-path (model-path)
           #:command (sidecar-command)
           #:context-size 128
           #:threads 1
           #:seed 0)))
  (lambda ()
    (define started-ms (current-inexact-milliseconds))
    (define tok (llama-cpp-backend-tokenizer backend))
    (define provider (llama-cpp-backend-provider backend))
    (define prompt "Say one word.")
    (define ids (tokenizer-tokenize tok prompt))
    (define roundtrip (tokenizer-detokenize tok ids))
    (define filter
      (make-choice-filter
       (list (make-lit-filter tok " yes")
             (make-lit-filter tok " no"))))
    (define generated
      (generate provider ids filter
                #:candidate-policy 'allowed-only
                #:seed 0
                #:temperature 0.7
                #:max-tokens 2))
    (define generated-text
      (tokenizer-detokenize tok (generation-result-token-ids generated)))
    (define payload
      (hash 'ok #t
            'model_path (model-path)
            'roundtrip_ok (string=? prompt roundtrip)
            'token_count (length ids)
            'generation_status (symbol->string (generation-result-status generated))
            'generated_text generated-text
            'generated_tokens (generation-result-generated-tokens generated)
            'latency_ms (- (current-inexact-milliseconds) started-ms)))
    (cond
      [(output-path)
       (call-with-output-file (output-path)
         (lambda (out) (write-payload payload out))
         #:exists 'replace)]
      [else
       (write-payload payload (current-output-port))]))
  (lambda ()
    (when backend
      ((llama-cpp-backend-close! backend)))))
