#lang racket/base

(require json
         racket/cmdline
         racket/file
         racket/list
         racket/match
         racket/path
         racket/random
         racket/string
         rack-llm
         rack-llm/model-llama-cpp)

(define specs-path (make-parameter "data/012_pwsg_specs.jsonl"))
(define output-path
  (make-parameter "experiments/012_real_model_benchmark/results/012_pwsg_generation_raw.jsonl"))
(define models-dir
  (make-parameter "experiments/012_real_model_benchmark/results/weak-models"))
(define model-path
  (make-parameter
   (or (getenv "RACK_LLM_GGUF_MODEL")
       "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")))
(define calibration-min (make-parameter 256))
(define calibration-per-rule (make-parameter 20))
(define eval-samples (make-parameter 16))
(define max-tokens (make-parameter 32))
(define limit-templates (make-parameter #f))
(define temperature (make-parameter 0.7))

(command-line
 #:program "racket_pwsg_pipeline.rkt"
 #:once-each
 [("--specs") path "PWSG specs JSONL" (specs-path path)]
 [("--output") path "Raw output JSONL" (output-path path)]
 [("--models-dir") path "Weak model directory" (models-dir path)]
 [("--model-path") path "GGUF model" (model-path path)]
 [("--calibration-min") n "Minimum calibration candidates" (calibration-min (string->number n))]
 [("--calibration-per-rule") n "Calibration candidates per weak rule" (calibration-per-rule (string->number n))]
 [("--eval-samples") n "Evaluation samples per method" (eval-samples (string->number n))]
 [("--max-tokens") n "Generation horizon" (max-tokens (string->number n))]
 [("--limit-templates") n "Limit templates for smoke" (limit-templates (string->number n))]
 [("--temperature") n "Sampling temperature" (temperature (string->number n))])

(define noises '(clean noisy_20 noisy_40))
(define methods '(pwsg_cars hard_only_cars posterior_rerank posterior_rejection))

(define (read-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (for/list ([line (in-lines in)] #:when (not (string=? "" (string-trim line))))
        (string->jsexpr line)))))

(define (field table key)
  (hash-ref table key (lambda () (error 'pwsg-012 "missing field ~a" key))))

(define (make-spec row noise)
  (define rule-sets (field row 'rule_sets))
  (define raw-rules (field rule-sets noise))
  (define rules
    (for/list ([raw (in-list raw-rules)])
      (define pattern (lit (field raw 'pattern)))
      (case (string->symbol (field raw 'polarity))
        [(prefer) (prefer pattern)]
        [(avoid) (avoid pattern)]
        [(ban) (ban pattern)]
        [else (error 'pwsg-012 "unknown polarity ~a" (field raw 'polarity))])))
  (apply control (text (max-tokens)) rules))

(define (safe-name template noise)
  (format "~a__~a.json"
          (regexp-replace* #px"[^A-Za-z0-9._-]+" template "_") noise))

(define (group-rows rows)
  (define groups (make-hash))
  (for ([row (in-list rows)])
    (hash-update! groups (field row 'template) (lambda (xs) (cons row xs)) '()))
  (sort (hash->list groups) string<? #:key car))

(define (sample-hard backend row noise count seed)
  (define spec (make-spec row noise))
  (define compiled (compile-spec backend spec))
  (define generator
    (make-generator compiled (field row 'prompt)
                    #:sampler (cars-sampler #:max-attempts 100 #:ignore-weak? #t)
                    #:temperature (temperature) #:max-tokens (max-tokens) #:seed seed))
  (dynamic-wind
    void
    (lambda ()
      (for/list ([i (in-range count)])
        (define result (generator-sample! generator))
        (unless (eq? (generation-result-status result) 'found)
          (error 'pwsg-012 "hard calibration generation failed for ~a/~a: ~a"
                 (field row 'key) noise (generation-result-reason result)))
        (cons result (observe compiled result))))
    (lambda ()
      (generator-close! generator)
      (compiled-spec-close! compiled))))

(define (fit-group backend template rows noise group-index)
  (define first-spec (make-spec (car rows) noise))
  (define first-compiled (compile-spec backend first-spec))
  (define weak-count (vector-length
                      (weak-observation-labels
                       (observe first-compiled ""))))
  (compiled-spec-close! first-compiled)
  (define target (max (calibration-min) (* (calibration-per-rule) weak-count)))
  (define base (quotient target (length rows)))
  (define extra (remainder target (length rows)))
  (define observations
    (append*
     (for/list ([row (in-list rows)] [row-index (in-naturals)])
       (define count (+ base (if (< row-index extra) 1 0)))
       (map cdr (sample-hard backend row noise count
                             (+ 12000000 (* group-index 100000) (* row-index 1000)))))))
  (define model (fit-weak-model observations #:seed (+ 9100 group-index)))
  (make-directory* (models-dir))
  (define path (build-path (models-dir) (safe-name template noise)))
  (save-weak-model model path)
  model)

(define (result-posterior weak-model compiled result)
  (weak-posterior weak-model (observe compiled result)))

(define (result-row row template noise method sample-index result posterior observation weak-model)
  (define metrics (generation-result-metrics result))
  (hash 'key (field row 'key)
        'template template
        'noise (symbol->string noise)
        'method (symbol->string method)
        'sample_index sample-index
        'status (symbol->string (generation-result-status result))
        'reason (or (generation-result-reason result) #f)
        'text (generation-result-text result)
        'token_ids (generation-result-token-ids result)
        'lm_logprob (or (generation-result-lm-logprob result) #f)
        'target_log_weight (or (generation-result-target-log-weight result) #f)
        'posterior posterior
        'weak_model_fingerprint (weak-model-fingerprint weak-model)
        'schema_fingerprint
        (weak-observation-schema-fingerprint observation)
        'distribution_guarantee
        (symbol->string (generation-result-distribution-guarantee result))
        'weak_policy (symbol->string (generation-metrics-weak-policy metrics))
        'attempts (generation-metrics-attempts metrics)
        'hard_invalid_attempts (generation-metrics-hard-invalid-attempts metrics)
        'weak_rejections (generation-metrics-weak-rejections metrics)
        'trie_nodes (generation-metrics-trie-nodes metrics)
        'llm_calls (generation-metrics-llm-calls metrics)
        'generated_tokens (length (generation-result-token-ids result))))

(define (evaluate-method backend row template noise method weak-model sample-index seed)
  (define spec (make-spec row noise))
  (define compiled (compile-spec backend spec))
  (define (one-hard offset)
    (generate compiled (field row 'prompt)
              #:sampler (cars-sampler #:max-attempts 100 #:ignore-weak? #t)
              #:temperature (temperature) #:max-tokens (max-tokens) #:seed (+ seed offset)))
  (dynamic-wind
    void
    (lambda ()
      (define-values (result posterior)
        (case method
          [(pwsg_cars)
           (define result
             (generate compiled (field row 'prompt)
                       #:sampler (cars-sampler #:max-attempts 100 #:weak-model weak-model)
                       #:temperature (temperature) #:max-tokens (max-tokens) #:seed seed))
           (values result (result-posterior weak-model compiled result))]
          [(hard_only_cars)
           (define result (one-hard 0))
           (values result (result-posterior weak-model compiled result))]
          [(posterior_rerank)
           (define candidates (for/list ([i (in-range 4)]) (one-hard i)))
           (define result
             (argmax (lambda (r) (result-posterior weak-model compiled r)) candidates))
           (values result (result-posterior weak-model compiled result))]
          [(posterior_rejection)
           (define rng (make-pseudo-random-generator))
           (parameterize ([current-pseudo-random-generator rng]) (random-seed (+ seed 7000000)))
           (let loop ([attempt 0])
             (when (>= attempt 100) (error 'pwsg-012 "posterior rejection exhausted attempts"))
             (define result (one-hard attempt))
             (define posterior (result-posterior weak-model compiled result))
             (if (parameterize ([current-pseudo-random-generator rng]) (< (random) posterior))
                 (values result posterior)
                 (loop (add1 attempt))))]
          [else (error 'pwsg-012 "unknown method ~a" method)]))
      (values result posterior (observe compiled result)))
    (lambda () (compiled-spec-close! compiled))))

(define rows (read-jsonl (specs-path)))
(when (< (length rows) 150) (error 'pwsg-012 "fewer than 150 PWSG rows"))
(define groups0 (group-rows rows))
(define groups (if (limit-templates) (take groups0 (min (limit-templates) (length groups0))) groups0))
(define backend
  (llama-cpp-model #:model-path (model-path) #:context-size 256 #:threads 1 #:gpu-layers -1))

(make-directory* (or (path-only (output-path)) "."))
(call-with-output-file (output-path)
  (lambda (out)
    (dynamic-wind
      void
      (lambda ()
        (for ([entry (in-list groups)] [template-index (in-naturals)])
          (for ([noise (in-list noises)] [noise-index (in-naturals)])
            (define group-index (+ (* template-index (length noises)) noise-index))
            (define template (car entry))
            (define template-rows (reverse (cdr entry)))
            (eprintf "fit ~a / ~a (~a rows)\n" template noise (length template-rows))
            (define weak-model (fit-group backend template template-rows noise group-index))
            (for* ([row (in-list template-rows)]
                   [method (in-list methods)]
                   [sample-index (in-range (eval-samples))])
              (define seed (+ 50000000 (* group-index 1000000)
                              (* sample-index 100) (index-of methods method)))
              (define-values (result posterior observation)
                (evaluate-method backend row template noise method weak-model sample-index seed))
              (unless (eq? (generation-result-status result) 'found)
                (error 'pwsg-012 "evaluation failed for ~a/~a/~a: ~a"
                       (field row 'key) noise method (generation-result-reason result)))
              (write-json (result-row row template noise method sample-index result posterior
                                      observation weak-model) out)
              (newline out)
              (flush-output out)))))
      (lambda () (model-close! backend))))
  #:exists 'truncate/replace)

(displayln
 (jsexpr->string
  (hash 'status "complete" 'templates (length groups) 'rows (length rows)
        'noise_levels (length noises) 'methods (length methods)
        'eval_samples (eval-samples))))
