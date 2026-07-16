#lang racket/base

(require json
         racket/cmdline
         racket/format
         racket/list
         racket/string
         rack-llm
         rack-llm/model-llama-cpp)

(define default-gguf-model-path
  "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
(define input-path (make-parameter "data/soft_ifbench_rules.jsonl"))
(define output-path (make-parameter "experiments/012_real_model_benchmark/results/012_soft_candidate_pool.raw.jsonl"))
(define model-path (make-parameter (or (getenv "RACK_LLM_GGUF_MODEL") default-gguf-model-path)))
(define candidates-per-row (make-parameter 16))
(define max-tokens (make-parameter 96))
(define temperature (make-parameter 0.7))
(define seeds (make-parameter '(0 1 2 3 4)))
(define limit-rows (make-parameter #f))
(define prompt-mode (make-parameter "original"))

(command-line
 #:program "racket_soft_candidate_pool.rkt"
 #:once-each
 [("--input") path "Input soft rule rows JSONL" (input-path path)]
 [("--output") path "Output raw candidate JSONL" (output-path path)]
 [("--model-path") path "GGUF model file" (model-path path)]
 [("--candidates-per-row") n "Candidates per input row" (candidates-per-row (string->number n))]
 [("--max-tokens") n "Generation token budget" (max-tokens (string->number n))]
 [("--temperature") n "Sampling temperature" (temperature (string->number n))]
 [("--seeds") csv "Comma-separated integer seeds"
              (seeds (map string->number (string-split csv ",")))]
 [("--limit-rows") n "Limit input rows" (limit-rows (string->number n))]
 [("--prompt-mode") mode "original, strict_final, or strict_chat_no_think"
                    (prompt-mode mode)])

(define (read-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (for/list ([line (in-lines in)]
                 #:when (not (string=? "" (string-trim line))))
        (string->jsexpr line)))))

(define (hget table key [default (lambda () (error 'hget "missing key ~a in ~s" key table))])
  (hash-ref table key
            (lambda ()
              (hash-ref table (symbol->string key)
                        (lambda ()
                          (if (procedure? default) (default) default))))))

(define (sample-counts total seed-values)
  (define len (length seed-values))
  (define base (quotient total len))
  (define extra (remainder total len))
  (for/list ([seed (in-list seed-values)]
             [index (in-naturals)])
    (cons seed (+ base (if (< index extra) 1 0)))))

(define (pool-source-for mode)
  (cond
    [(equal? mode "original") "real_qwen_native_unconstrained"]
    [(equal? mode "strict_final") "real_qwen_native_strict_final"]
    [(equal? mode "strict_chat_no_think") "real_qwen_native_strict_chat_no_think"]
    [else (error 'pool-source-for "unsupported prompt mode: ~a" mode)]))

(define (prompt-for row mode)
  (define prompt (hget row 'prompt))
  (cond
    [(equal? mode "original") prompt]
    [(equal? mode "strict_final")
     (string-append
      "You are being evaluated by a strict automatic instruction checker. "
      "Follow every constraint exactly. Do not include analysis, hidden reasoning, "
      "or explanations unless the user asked for them. Return only the final answer.\n\n"
      prompt)]
    [(equal? mode "strict_chat_no_think")
     (string-append
      "<|im_start|>user\n"
      "You are being evaluated by a strict automatic instruction checker. "
      "Follow every constraint exactly. Return only the final answer.\n\n"
      prompt
      "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")]
    [else (error 'prompt-for "unsupported prompt mode: ~a" mode)]))

(define (json-number value)
  (if (and (real? value) (rational? value))
      value
      #f))

(define (result-row row row-index candidate-index seed batch-index result source)
  (hash 'key (hget row 'key)
        'candidate_id (format "~a:~a" (hget row 'key) (~r candidate-index #:min-width 3 #:pad-string "0"))
        'candidate_index candidate-index
        'seed seed
        'batch_sample_index batch-index
        'pool_source source
        'generation_status (if (eq? (generation-result-status result) 'found) "GENERATED" "ERROR")
        'failure_reason (or (generation-result-reason result) "")
        'text (generation-result-text result)
        'ids (generation-result-token-ids result)
        'lm_logprob (json-number (generation-result-lm-logprob result))
        'latency_ms (generation-result-latency-ms result)
        'generated_tokens (length (generation-result-token-ids result))
        'finish_reason (symbol->string (generation-result-status result))
        'generation_metadata
        (hash 'model (model-path)
              'backend "racket_generate_native_llama_cpp_free"
              'temperature (temperature)
              'max_tokens (max-tokens)
              'seed seed
              'row_index row-index
              'prompt_mode (prompt-mode))))

(define model
  (llama-cpp-model
   #:model-path (model-path)
   #:context-size 512
   #:threads 1
   #:gpu-layers -1))

(define source (pool-source-for (prompt-mode)))
(define all-rows (read-jsonl (input-path)))
(define rows
  (if (limit-rows)
      (take all-rows (min (limit-rows) (length all-rows)))
      all-rows))
(define compiled (compile-spec model (text (max-tokens))))

(call-with-output-file (output-path)
  (lambda (out)
    (for ([row (in-list rows)]
          [row-index (in-naturals)])
      (define candidate-index 0)
      (for ([seed-count (in-list (sample-counts (candidates-per-row) (seeds)))])
        (define seed (car seed-count))
        (define count (cdr seed-count))
        (for ([batch-index (in-range count)])
          (define result
            (generate compiled
                      (prompt-for row (prompt-mode))
                      #:sampler (cars-sampler #:max-attempts 100)
                      #:seed (+ seed batch-index)
                      #:temperature (temperature)
                      #:max-tokens (max-tokens)))
          (write-json (result-row row row-index candidate-index seed batch-index result source) out)
          (newline out)
          (flush-output out)
          (set! candidate-index (add1 candidate-index))))))
  #:exists 'replace)

(compiled-spec-close! compiled)
(model-close! model)
(displayln
 (jsexpr->string
  (hash 'rows (* (length rows) (candidates-per-row))
        'input_rows (length rows)
        'pool_source source
        'backend "racket_generate_native_llama_cpp_free")))
