#lang racket/base

(require json
         racket/cmdline
         racket/list
         racket/match
         racket/string
         rack-llm
         rack-llm/llama-cpp)

(define rules-path (make-parameter "data/012_soft_ifbench_rules_audited.jsonl"))
(define output-path
  (make-parameter "experiments/012_real_model_benchmark/results/019_ours_soft_smoke_raw.jsonl"))
(define model-path (make-parameter "/mnt/storage/models/qwen/Qwen3.5-4B"))
(define sidecar-command
  (make-parameter
   ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/hf_logits_sidecar.py --model-path /mnt/storage/models/qwen/Qwen3.5-4B"))
(define limit-rows (make-parameter 5))
(define max-tokens (make-parameter 64))
(define beta (make-parameter 1.0))
(define temperature (make-parameter 0.7))
(define attempt-timeout-seconds (make-parameter #f))

(command-line
 #:program "racket_ours_soft_smoke.rkt"
 #:once-each
 [("--rules") path "Audited soft rules JSONL" (rules-path path)]
 [("--output") path "Output JSONL" (output-path path)]
 [("--model-path") path "Hugging Face model directory" (model-path path)]
 [("--sidecar-command") command "Command used by make-llama-cpp-provider" (sidecar-command command)]
 [("--limit-rows") n "Number of audited rows for smoke" (limit-rows (string->number n))]
 [("--max-tokens") n "Generation token budget" (max-tokens (string->number n))]
 [("--beta") n "Soft guide beta" (beta (string->number n))]
 [("--temperature") n "Sampling temperature" (temperature (string->number n))]
 [("--attempt-timeout-seconds") n "Per row/noise generation timeout; 0 disables" (attempt-timeout-seconds (let ([value (string->number n)]) (and value (positive? value) value)))])

(define noise-levels '("clean" "noisy_20" "noisy_40"))

(define (hget table key [default (lambda () (error 'hget "missing key ~a in ~s" key table))])
  (hash-ref table key
            (lambda ()
              (hash-ref table (symbol->string key)
                        (lambda ()
                          (if (procedure? default) (default) default))))))

(define (read-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (for/list ([line (in-lines in)]
                 #:when (not (string=? "" (string-trim line))))
        (string->jsexpr
         (string-replace line "-Infinity" "\"-Infinity\""))))))

(define (python-regex->pregexp-pattern pattern)
  (define normalized
    (string-replace
     (string-replace pattern "\\n" "\n")
     "\\t" "\t"))
  (define m (regexp-match #rx"^\\(\\?([ims]+)\\)(.*)$" normalized))
  (if m
      (format "(?~a:~a)" (cadr m) (regexp-replace* #rx"\\(\\?[ims]+\\)" (caddr m) ""))
      (regexp-replace* #rx"\\(\\?[ims]+\\)" normalized "")))

(define (rule->watcher rule)
  (define kind (hget rule 'kind))
  (define weight (hget rule 'weight 0.0))
  (define pattern-type (hget rule 'pattern_type))
  (define pattern (hget rule 'pattern))
  (define expr
    (cond
      [(equal? pattern-type "regex") (rx (pregexp (python-regex->pregexp-pattern pattern)))]
      [(equal? pattern-type "literal") pattern]
      [else (error 'rule->watcher "unsupported pattern_type: ~a" pattern-type)]))
  (cond
    [(equal? kind "rank") (rank weight expr)]
    [(equal? kind "ban") (ban expr)]
    [else (error 'rule->watcher "unsupported rule kind: ~a" kind)]))

(define (row-rules row noise)
  (define rule-sets (hget row 'rule_sets))
  (hget rule-sets (string->symbol noise)))

(define (make-guide row noise)
  (define watchers (map rule->watcher (row-rules row noise)))
  (keyword-apply text
                 '(#:max-tokens)
                 (list (* 16 (max-tokens)))
                 watchers))

(define (json-number value)
  (if (and (real? value) (rational? value))
      value
      #f))

(define (jsexpr-or-string value)
  (cond
    [(symbol? value) (symbol->string value)]
    [(number? value) (json-number value)]
    [(or (string? value) (boolean? value)) value]
    [(not value) #f]
    [else (format "~s" value)]))

(define (result->payload row noise result seed)
  (hash 'key (hget row 'key)
        'method "ours_soft_decoding"
        'noise noise
        'seed seed
        'status (symbol->string (generation-result-status result))
        'failure_reason (jsexpr-or-string (generation-result-reason result))
        'text (generation-result-text result)
        'lm_logprob (json-number (generation-result-lm-logprob result))
        'guide_score (json-number (generation-result-guide-score result))
        'total_score (json-number (generation-result-total-score result))
        'latency_ms (generation-result-latency-ms result)
        'generated_tokens (generation-result-generated-tokens result)
        'trace (format "~s" (generation-result-trace result))
        'metrics (format "~s" (generation-result-metrics result))
        'generation_backend "racket_generate_hf_sidecar"
        'uses_candidate_pool #f
        'uses_official_verifier #f))

(define (failure->payload row noise seed reason)
  (hash 'key (hget row 'key)
        'method "ours_soft_decoding"
        'noise noise
        'seed seed
        'status "error"
        'failure_reason reason
        'text ""
        'lm_logprob #f
        'guide_score #f
        'total_score #f
        'latency_ms 0.0
        'generated_tokens 0
        'trace ""
        'metrics ""
        'generation_backend "racket_generate_hf_sidecar"
        'uses_candidate_pool #f
        'uses_official_verifier #f))

(define (call-with-attempt-timeout timeout-seconds thunk)
  (cond
    [(not timeout-seconds) (list 'ok (thunk))]
    [else
     (define ch (make-channel))
     (define worker
       (thread
        (lambda ()
          (with-handlers ([exn:fail?
                           (lambda (exn)
                             (channel-put ch (list 'error (exn-message exn))))])
            (channel-put ch (list 'ok (thunk)))))))
     (define result (sync/timeout timeout-seconds ch))
     (cond
       [result result]
       [else
        (kill-thread worker)
        (list 'error (format "generation attempt timed out after ~a seconds" timeout-seconds))])]))

(define (write-jsonl path rows)
  (call-with-output-file path
    (lambda (out)
      (for ([row (in-list rows)])
        (write-json row out)
        (newline out)))
    #:exists 'replace))

(define p
  (make-llama-cpp-provider
   #:model-path (model-path)
   #:command (sidecar-command)
   #:context-size 512
   #:threads 1
   #:seed 0))

(define all-input-rows (read-jsonl (rules-path)))
(define input-rows (take all-input-rows (min (limit-rows) (length all-input-rows))))

(define outputs
  (for*/list ([row (in-list input-rows)]
              [noise-index (in-range (length noise-levels))])
    (define noise (list-ref noise-levels noise-index))
    (define seed (+ (* 1000 (string->number (format "~a" (hget row 'key)))) noise-index))
    (match (call-with-attempt-timeout
            (attempt-timeout-seconds)
            (lambda ()
              (define result
                (generate p
                          (hget row 'prompt)
                          (make-guide row noise)
                          #:beta (beta)
                          #:seed seed
                          #:temperature (temperature)
                          #:max-tokens (max-tokens)))
              (result->payload row noise result seed)))
      [(list 'ok payload) payload]
      [(list 'error reason) (failure->payload row noise seed reason)])))

(write-jsonl (output-path) outputs)
(displayln (jsexpr->string (hash 'rows (length outputs)
                                  'input_rows (length input-rows)
                                  'noise_levels noise-levels)))
