#lang racket/base

(require json
         racket/cmdline
         racket/list
         racket/match
         racket/port
         racket/string
         rack-llm
         rack-llm/llama-cpp)

(define rules-path (make-parameter "data/012_soft_ifbench_rules_audited.jsonl"))
(define output-path
  (make-parameter "experiments/012_real_model_benchmark/results/012_ours_soft_generation_raw.jsonl"))
(define model-path (make-parameter "/mnt/storage/models/qwen/Qwen3.5-4B"))
(define sidecar-command
  (make-parameter
   ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/hf_logits_sidecar.py --model-path /mnt/storage/models/qwen/Qwen3.5-4B"))
(define limit-rows (make-parameter #f))
(define samples (make-parameter 16))
(define top-k (make-parameter 128))
(define provider-mode-param (make-parameter "exact-full-vocab"))
(define deadline-ms (make-parameter 5000))
(define max-tokens (make-parameter 96))
(define temperature (make-parameter 0.7))

(command-line
 #:program "racket_ours_soft_batch.rkt"
 #:once-each
 [("--rules") path "Audited soft rules JSONL" (rules-path path)]
 [("--output") path "Output JSONL" (output-path path)]
 [("--model-path") path "Hugging Face model directory" (model-path path)]
 [("--sidecar-command") command "HF JSON-lines sidecar command" (sidecar-command command)]
 [("--limit-rows") n "Limit audited rows; omitted means all rows" (limit-rows (string->number n))]
 [("--samples") n "Samples per row/noise/method" (samples (string->number n))]
 [("--top-k") n "Top-k token shortlist size" (top-k (string->number n))]
 [("--provider-mode") mode "exact-full-vocab or top-k-approx"
                       (provider-mode-param mode)]
 [("--deadline-ms") n "Per generate call Racket deadline" (deadline-ms (string->number n))]
 [("--max-tokens") n "Per generate call token budget" (max-tokens (string->number n))]
 [("--temperature") n "Sampling temperature" (temperature (string->number n))])

(unless (member (provider-mode-param) '("exact-full-vocab" "top-k-approx"))
  (error 'racket_ours_soft_batch "unsupported --provider-mode: ~a" (provider-mode-param)))

(define noise-levels '("clean" "noisy_20" "noisy_40"))
(define methods '("ours_soft_decoding" "ours_hybrid_decoding"))

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
    (decode-python-unicode-escapes
     (string-replace
      (string-replace pattern "\\n" "\n")
      "\\t" "\t")))
  (define m (regexp-match #rx"^\\(\\?([ims]+)\\)(.*)$" normalized))
  (if m
      (format "(?~a:~a)" (cadr m) (regexp-replace* #rx"\\(\\?[ims]+\\)" (caddr m) ""))
      (regexp-replace* #rx"\\(\\?[ims]+\\)" normalized "")))

(define (decode-python-unicode-escapes pattern)
  (regexp-replace*
   #px"\\\\U([0-9A-Fa-f]{8})|\\\\u([0-9A-Fa-f]{4})"
   pattern
   (lambda captures
     (define hex
       (or (and (>= (length captures) 2) (list-ref captures 1))
           (and (>= (length captures) 3) (list-ref captures 2))))
     (string (integer->char (string->number hex 16))))))

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
                 '(4096)
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

(define (make-sidecar command)
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f "/bin/sh" "-c" command))
  (define (request payload)
    (write-json payload stdin)
    (newline stdin)
    (flush-output stdin)
    (define line (read-line stdout 'any))
    (when (eof-object? line)
      (error 'soft-batch-sidecar "sidecar closed stdout: ~a" (port->string stderr)))
    (define response (string->jsexpr line))
    (unless (equal? (hget response 'ok #f) #t)
      (error 'soft-batch-sidecar "sidecar response is not ok: ~s" response))
    response)
  (define (close)
    (with-handlers ([exn:fail? void])
      (write-json (hash 'op "close") stdin)
      (newline stdin)
      (flush-output stdin))
    (close-output-port stdin)
    (subprocess-wait proc))
  (values request close))

(define (make-topk-provider tokens logits metadata)
  (make-provider
   #:vocab tokens
   #:mode 'top-k-approx
   #:metadata metadata
   #:next-logits (lambda (_prompt _prefix) (list->vector logits))))

(define (method-beta method)
  (cond
    [(equal? method "ours_soft_decoding") 1.0]
    [(equal? method "ours_hybrid_decoding") 1.0]
    [else (error 'method-beta "unknown method: ~a" method)]))

(define (method-seed-offset method)
  (if (equal? method "ours_hybrid_decoding") 10000000 0))

(define (result->payload row noise method sample-index result provider-kind model-vocab-size topk-response)
  (define metrics (generation-result-metrics result))
  (hash 'key (hget row 'key)
        'example_id (hget row 'key)
        'method method
        'noise noise
        'sample_index sample-index
        'candidate_id sample-index
        'seed (+ (method-seed-offset method)
                 (* 100000 sample-index)
                 (* 1000 (string->number (format "~a" (hget row 'key))))
                 (index-of noise-levels noise))
        'status (symbol->string (generation-result-status result))
        'failure_reason (jsexpr-or-string (generation-result-reason result))
        'text (generation-result-text result)
        'lm_logprob (json-number (generation-result-lm-logprob result))
        'guide_score (json-number (generation-result-guide-score result))
        'weak_score (json-number (generation-result-guide-score result))
        'total_score (json-number (generation-result-total-score result))
        'latency_ms (generation-result-latency-ms result)
        'generated_tokens (generation-result-generated-tokens result)
        'trace (format "~s" (generation-result-trace result))
        'metrics (format "~s" metrics)
        'provider_mode provider-kind
        'approximation (if (equal? provider-kind "top-k-approx")
                           "top_k_logits_shortlist"
                           "none")
        'top_k (and topk-response (hget topk-response 'k))
        'model_vocab_size model-vocab-size
        'generation_backend (if (equal? provider-kind "top-k-approx")
                                "racket_generate_hf_sidecar_topk"
                                "racket_generate_hf_sidecar_full_vocab")
        'uses_candidate_pool #f
        'uses_official_verifier_for_selection #f
        'uses_official_verifier #f
        'hybrid_fallback (equal? method "ours_hybrid_decoding")))

(define (failure->payload row noise method sample-index reason)
  (hash 'key (hget row 'key)
        'example_id (hget row 'key)
        'method method
        'noise noise
        'sample_index sample-index
        'candidate_id sample-index
        'seed (+ (method-seed-offset method)
                 (* 100000 sample-index)
                 (* 1000 (string->number (format "~a" (hget row 'key))))
                 (index-of noise-levels noise))
        'status "error"
        'failure_reason reason
        'text ""
        'lm_logprob #f
        'guide_score #f
        'weak_score #f
        'total_score #f
        'latency_ms 0.0
        'generated_tokens 0
        'trace ""
        'metrics ""
        'provider_mode (provider-mode-param)
        'approximation (if (equal? (provider-mode-param) "top-k-approx")
                           "top_k_logits_shortlist"
                           "none")
        'top_k (and (equal? (provider-mode-param) "top-k-approx") (top-k))
        'model_vocab_size #f
        'generation_backend (if (equal? (provider-mode-param) "top-k-approx")
                                "racket_generate_hf_sidecar_topk"
                                "racket_generate_hf_sidecar_full_vocab")
        'uses_candidate_pool #f
        'uses_official_verifier_for_selection #f
        'uses_official_verifier #f
        'hybrid_fallback (equal? method "ours_hybrid_decoding")))

(define (write-jsonl path rows)
  (call-with-output-file path
    (lambda (out)
      (for ([row (in-list rows)])
        (write-json row out)
        (newline out)))
    #:exists 'replace))

(define-values (sidecar-request close-sidecar)
  (if (equal? (provider-mode-param) "top-k-approx")
      (make-sidecar (sidecar-command))
      (values #f void)))

(define _load-response
  (and sidecar-request
       (sidecar-request
        (hash 'op "load"
              'model_path (path->string (if (path? (model-path))
                                            (model-path)
                                            (string->path (model-path))))))))

(define exact-provider
  (and (equal? (provider-mode-param) "exact-full-vocab")
       (make-llama-cpp-provider
        #:model-path (model-path)
        #:command (sidecar-command)
        #:context-size 512
        #:threads 1
        #:seed 0)))

(define (make-run-provider topk-response)
  (if exact-provider
      exact-provider
      (make-topk-provider (hget topk-response 'tokens)
                          (hget topk-response 'logits)
                          (hash 'provider-mode 'top-k-approx
                                'approximation 'top_k_logits_shortlist
                                'top-k (hget topk-response 'k)))))

(define (run-provider-kind)
  (if exact-provider "exact-full-vocab" "top-k-approx"))

(define (run-model-vocab-size topk-response)
  (if exact-provider
      (length (provider-vocab exact-provider))
      (hget topk-response 'vocab_size)))

(define all-input-rows (read-jsonl (rules-path)))
(define input-rows
  (if (limit-rows)
      (take all-input-rows (min (limit-rows) (length all-input-rows)))
      all-input-rows))

(define outputs
  (append*
   (for*/list ([row (in-list input-rows)]
               [noise (in-list noise-levels)])
     (with-handlers ([exn:fail?
                      (lambda (exn)
                        (append*
                         (for/list ([method (in-list methods)])
                           (for/list ([sample-index (in-range (samples))])
                             (failure->payload row noise method sample-index (exn-message exn))))))])
       (define topk-response
         (and sidecar-request
              (sidecar-request
               (hash 'op "next_topk"
                     'prompt (hget row 'prompt)
                     'prefix ""
                     'k (top-k)))))
       (append*
        (for/list ([method (in-list methods)])
          (for/list ([sample-index (in-range (samples))])
            (define seed (+ (method-seed-offset method)
                            (* 100000 sample-index)
                            (* 1000 (string->number (format "~a" (hget row 'key))))
                            (index-of noise-levels noise)))
            (define provider (make-run-provider topk-response))
            (define result
              (generate provider
                        (hget row 'prompt)
                        (make-guide row noise)
                        #:beta (method-beta method)
                        #:seed seed
                        #:temperature (temperature)
                        #:deadline-ms (deadline-ms)
                        #:max-tokens (max-tokens)))
            (result->payload row
                             noise
                             method
                             sample-index
                             result
                             (run-provider-kind)
                             (run-model-vocab-size topk-response)
                             topk-response))))))))

(write-jsonl (output-path) outputs)
(close-sidecar)
(displayln (jsexpr->string (hash 'rows (length outputs)
                                  'input_rows (length input-rows)
                                  'noise_levels noise-levels
                                  'methods methods
                                  'samples (samples)
                                  'provider_mode (provider-mode-param)
                                  'max_tokens (max-tokens)
                                  'top_k (and (equal? (provider-mode-param) "top-k-approx") (top-k))
                                  'approximation (if (equal? (provider-mode-param) "top-k-approx")
                                                     "top_k_logits_shortlist"
                                                     "none"))))
