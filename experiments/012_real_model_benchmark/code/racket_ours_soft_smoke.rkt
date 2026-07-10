#lang racket/base

(require json
         racket/cmdline
         racket/list
         racket/match
         racket/string
         rack-llm
         rack-llm/model-llama-cpp)

(define rules-path (make-parameter "data/012_soft_ifbench_rules_audited.jsonl"))
(define output-path
  (make-parameter "experiments/012_real_model_benchmark/results/019_ours_soft_smoke_raw.jsonl"))
(define default-gguf-model-path
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define model-path (make-parameter (or (getenv "RACK_LLM_GGUF_MODEL") default-gguf-model-path)))
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
 [("--model-path") path "GGUF model file" (model-path path)]
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
        (string->jsexpr line)))))

(define (json-number-field value field-name)
  (cond
    [(number? value) value]
    [(equal? value "-Infinity") -inf.0]
    [(equal? value "Infinity") +inf.0]
    [else (error 'json-number-field
                 "expected numeric JSON field ~a, got ~s"
                 field-name
                 value)]))

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
  (define weight (json-number-field (hget rule 'weight 0.0) 'weight))
  (define pattern-type (hget rule 'pattern_type))
  (define pattern (hget rule 'pattern))
  (define expr
    (cond
      [(equal? pattern-type "regex") (rx (python-regex->pregexp-pattern pattern))]
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
  (text (* 16 (max-tokens)) watchers))

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
        'guide_score (json-number (generation-result-filter-score result))
        'total_score (json-number (generation-result-total-score result))
        'latency_ms (generation-result-latency-ms result)
        'generated_tokens (generation-result-generated-tokens result)
        'trace (format "~s" (generation-result-trace result))
        'metrics (format "~s" (generation-result-metrics result))
        'provider_mode "exact-full-vocab"
        'approximation "none"
        'generation_backend "racket_generate_native_llama_cpp_full_vocab"
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
        'provider_mode "exact-full-vocab"
        'approximation "none"
        'generation_backend "racket_generate_native_llama_cpp_full_vocab"
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

(define model
  (llama-cpp-model
   #:model-path (model-path)
   #:context-size 512
   #:threads 1
   #:gpu-layers -1))

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
                (generate model
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
(model-close! model)
(displayln (jsexpr->string (hash 'rows (length outputs)
                                  'input_rows (length input-rows)
                                  'noise_levels noise-levels)))
