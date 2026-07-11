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
  (make-parameter "experiments/012_real_model_benchmark/results/012_ours_soft_generation_raw.jsonl"))
(define default-gguf-model-path
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define model-path (make-parameter (or (getenv "RACK_LLM_GGUF_MODEL") default-gguf-model-path)))
(define limit-rows (make-parameter #f))
(define samples (make-parameter 16))
(define deadline-ms (make-parameter 5000))
(define max-tokens (make-parameter 96))
(define temperature (make-parameter 0.7))

(command-line
 #:program "racket_ours_soft_batch.rkt"
 #:once-each
 [("--rules") path "Audited soft rules JSONL" (rules-path path)]
 [("--output") path "Output JSONL" (output-path path)]
 [("--model-path") path "GGUF model file" (model-path path)]
 [("--limit-rows") n "Limit audited rows; omitted means all rows" (limit-rows (string->number n))]
 [("--samples") n "Samples per row/noise/method" (samples (string->number n))]
 [("--deadline-ms") n "Per generate call Racket deadline" (deadline-ms (string->number n))]
 [("--max-tokens") n "Per generate call token budget" (max-tokens (string->number n))]
 [("--temperature") n "Sampling temperature" (temperature (string->number n))])

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

(define (rule->observer rule)
  (define kind (hget rule 'kind))
  (define weight (json-number-field (hget rule 'weight 0.0) 'weight))
  (define pattern-type (hget rule 'pattern_type))
  (define pattern (hget rule 'pattern))
  (cond
    [(and (equal? kind "rank") (equal? pattern-type "regex"))
     (rank-rx weight pattern)]
    [(and (equal? kind "rank") (equal? pattern-type "literal"))
     (rank weight pattern)]
    [(and (equal? kind "ban") (equal? pattern-type "regex"))
     (ban-rx pattern)]
    [(and (equal? kind "ban") (equal? pattern-type "literal"))
     (ban pattern)]
    [(not (or (equal? pattern-type "regex") (equal? pattern-type "literal")))
     (error 'rule->observer "unsupported pattern_type: ~a" pattern-type)]
    [else (error 'rule->observer "unsupported rule kind: ~a" kind)]))

(define (row-rules row noise)
  (define rule-sets (hget row 'rule_sets))
  (hget rule-sets (string->symbol noise)))

(define (make-guide row noise)
  (define observers (map rule->observer (row-rules row noise)))
  (text 4096 observers))

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

(define (method-beta method)
  (cond
    [(equal? method "ours_soft_decoding") 1.0]
    [(equal? method "ours_hybrid_decoding") 1.0]
    [else (error 'method-beta "unknown method: ~a" method)]))

(define (method-seed-offset method)
  (if (equal? method "ours_hybrid_decoding") 10000000 0))

(define (result->payload row noise method sample-index result)
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
        'guide_score (json-number (generation-result-guidance-score result))
        'weak_score (json-number (generation-result-guidance-score result))
        'total_score (json-number (generation-result-total-score result))
        'latency_ms (generation-result-latency-ms result)
        'generated_tokens (generation-result-generated-tokens result)
        'trace (format "~s" (generation-result-trace result))
        'metrics (format "~s" metrics)
        'provider_mode "exact-full-vocab"
        'approximation "none"
        'model_vocab_size (generation-metrics-vocab-size metrics)
        'generation_backend "racket_generate_native_llama_cpp_full_vocab"
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
        'provider_mode "exact-full-vocab"
        'approximation "none"
        'model_vocab_size #f
        'generation_backend "racket_generate_native_llama_cpp_full_vocab"
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

(define (call-with-attempt-timeout timeout-ms thunk)
  (cond
    [(or (not timeout-ms) (<= timeout-ms 0))
     (list 'ok (thunk))]
    [else
     (define ch (make-channel))
     (define worker
       (thread
        (lambda ()
          (with-handlers ([exn:fail?
                           (lambda (exn)
                             (channel-put ch (list 'error (exn-message exn))))])
            (channel-put ch (list 'ok (thunk)))))))
     (define result (sync/timeout (/ timeout-ms 1000.0) ch))
     (cond
       [result result]
       [else
        (kill-thread worker)
        (list 'error (format "generation attempt timed out after ~a ms" timeout-ms))])]))

(define model
  (llama-cpp-model
   #:model-path (model-path)
   #:context-size 512
   #:threads 1
   #:gpu-layers -1))

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
       (define guide (make-guide row noise))
       (append*
        (for/list ([method (in-list methods)])
          (for/list ([sample-index (in-range (samples))])
            (define seed (+ (method-seed-offset method)
                            (* 100000 sample-index)
                            (* 1000 (string->number (format "~a" (hget row 'key))))
                            (index-of noise-levels noise)))
            (match (call-with-attempt-timeout
                    (deadline-ms)
                    (lambda ()
                      (generate model
                                (hget row 'prompt)
                                guide
                                #:beta (method-beta method)
                                #:seed seed
                                #:temperature (temperature)
                                #:max-tokens (max-tokens))))
              [(list 'ok result)
               (result->payload row
                                noise
                                method
                                sample-index
                                result)]
              [(list 'error reason)
               (failure->payload row
                                 noise
                                 method
                                 sample-index
                                 reason)]))))))))

(write-jsonl (output-path) outputs)
(model-close! model)
(displayln (jsexpr->string (hash 'rows (length outputs)
                                  'input_rows (length input-rows)
                                  'noise_levels noise-levels
                                  'methods methods
                                  'samples (samples)
                                  'provider_mode "exact-full-vocab"
                                  'max_tokens (max-tokens)
                                  'approximation "none")))
