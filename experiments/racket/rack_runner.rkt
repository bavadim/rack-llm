#lang racket/base

(require json
         racket/cmdline
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         rack-llm)

(define mode (make-parameter "candidates"))
(define input-path (make-parameter #f))
(define candidates-path (make-parameter #f))
(define output-path (make-parameter #f))
(define models-dir (make-parameter #f))
(define model-path (make-parameter #f))
(define temperature (make-parameter 1.0))
(define seeds (make-parameter '(0)))
(define samples-per-seed (make-parameter 1))
(define max-attempts (make-parameter 128))
(define attempt-checkpoints (make-parameter '()))
(define deadline-ms (make-parameter 120000))
(define context-size (make-parameter 1024))
(define model-threads (make-parameter 1))
(define cohort-width (make-parameter 32))
(define batch-size (make-parameter 8192))
(define ubatch-size (make-parameter 512))
(define batch-threads (make-parameter 16))
(define factor-threads (make-parameter 16))
(define runtime-fingerprint (make-parameter #f))

(command-line
 #:program "rack_runner.rkt"
 #:once-each
 [("--mode") value "candidates, naive, observe, fit-score, score, or pwsg" (mode value)]
 [("--input") value "Instances JSONL" (input-path value)]
 [("--candidates") value "Candidates JSONL" (candidates-path value)]
 [("--output") value "Output JSONL" (output-path value)]
 [("--models-dir") value "Weak model directory" (models-dir value)]
 [("--model") value "GGUF path" (model-path value)]
 [("--temperature") value "Temperature" (temperature (string->number value))]
 [("--seeds") value "Comma separated seeds"
              (seeds (map string->number (string-split value ",")))]
 [("--samples-per-seed") value "Samples per seed"
                         (samples-per-seed (string->number value))]
 [("--max-attempts") value "CARS attempt budget"
                      (max-attempts (string->number value))]
 [("--attempt-checkpoints") value "Comma separated CARS attempt checkpoints"
                              (attempt-checkpoints
                               (map string->number (string-split value ",")))]
 [("--deadline-ms") value "Per sample deadline in ms, or none"
                    (deadline-ms (if (string-ci=? value "none")
                                     #f
                                     (string->number value)))]
 [("--context-size") value "llama.cpp context size"
                     (context-size (string->number value))]
 [("--model-threads") value "llama.cpp CPU threads"
                     (model-threads (string->number value))]
 [("--cohort-width") value "Fixed physical cohort width (1..32)"
                     (cohort-width (string->number value))]
 [("--batch-size") value "llama.cpp logical token batch"
                   (batch-size (string->number value))]
 [("--ubatch-size") value "llama.cpp physical token microbatch"
                    (ubatch-size (string->number value))]
 [("--batch-threads") value "llama.cpp prefill/batch CPU threads"
                      (batch-threads (string->number value))]
 [("--factor-threads") value "native factor-scan lane threads"
                       (factor-threads (string->number value))]
 [("--runtime-fingerprint") value "Frozen runtime resource configuration"
                            (runtime-fingerprint value)])

(unless (and (input-path) (output-path))
  (error 'rack-runner "--input and --output are required"))
(unless (runtime-fingerprint)
  (error 'rack-runner "--runtime-fingerprint is required"))
(when (and (not (memq (string->symbol (mode)) '(fit-score score)))
           (not (model-path)))
  (error 'rack-runner "--model is required for model-facing modes"))
(unless (and (exact-positive-integer? (cohort-width)) (<= (cohort-width) 32))
  (error 'rack-runner "--cohort-width must be in 1..32"))
(unless (andmap exact-positive-integer?
                (list (batch-size) (ubatch-size) (batch-threads) (factor-threads)))
  (error 'rack-runner "batch sizes and thread counts must be positive integers"))
(when (> (ubatch-size) (batch-size))
  (error 'rack-runner "--ubatch-size cannot exceed --batch-size"))

(define (read-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (for/list ([line (in-lines in)]
                 #:when (not (string=? "" (string-trim line))))
        (string->jsexpr line)))))

(define (get row key [default (lambda () (error 'rack-runner "missing ~a" key))])
  (hash-ref row key default))

(define (hard-program row)
  (define hard (get row 'hard_spec))
  (match (get hard 'kind)
    ["text" (text (get hard 'max_tokens))]
    ["ere" (ere (get hard 'pattern))]
    ["choice" (apply choice (map lit (get hard 'values)))]
    ["literal" (lit (get hard 'value))]
    [other (error 'rack-runner "unknown hard kind ~a" other)]))

(define (row-program row)
  (define rules
    (for/list ([raw (in-list (get row 'weak_rules '()))])
      (define pattern (ere (get raw 'pattern)))
      (if (string=? (get raw 'polarity) "positive")
          (positive pattern)
          (negative pattern))))
  (if (null? rules)
      (hard-program row)
      (apply with-rules (hard-program row) rules)))

(define (result-json row seed sample-index result)
  (hash
   'artifact_schema_version 2
   'prompt_id (get row 'id)
   'family (get row 'family)
   'split (get row 'split)
   'seed seed
   'sample_index sample-index
   'temperature (temperature)
   'runtime_fingerprint (runtime-fingerprint)
   'status (symbol->string (generation-result-status result))
   'reason (or (generation-result-reason result) #f)
   'text (generation-result-text result)
   'token_ids (generation-result-token-ids result)
   'token_count (length (generation-result-token-ids result))
   'lm_logprob (or (generation-result-lm-logprob result) #f)
   'hard_valid (eq? (generation-result-status result) 'found)
   'latency_ms (generation-result-latency-ms result)
   'tokenizer_fingerprint (generation-result-tokenizer-fingerprint result)
   'posterior (or (generation-result-posterior result) #f)
   'attempts (generation-result-attempts result)
   'rejected_attempts (if (eq? (generation-result-status result) 'found)
                          (sub1 (generation-result-attempts result))
                          (generation-result-attempts result))
   'proposed_tokens (generation-result-proposed-tokens result)
   'model_draws (generation-result-model-draws result)
   'trie_nodes (generation-result-trie-nodes result)))

(define rows (read-jsonl (input-path)))
(define model-free-mode? (memq (string->symbol (mode)) '(fit-score score)))
(define backend
  (and
   (not model-free-mode?)
   (llama-cpp-backend #:model-path (model-path)
                    #:cohort-width (cohort-width)
                    #:context-per-lane (context-size)
                    #:threads (model-threads)
                    #:batch-size (batch-size)
                    #:ubatch-size (ubatch-size)
                    #:batch-threads (batch-threads)
                    #:factor-threads (factor-threads)
                    #:gpu-layers -1
                    #:vocab-only? (eq? (string->symbol (mode)) 'observe))))

(define (write-row out row)
  (write-json row out)
  (newline out)
  (flush-output out))

;; Keep each prompt's jobs contiguous.  An oversized prompt is placed alone and
;; generate-batch partitions it into consecutive physical cohorts.
(define (pack-prompt-row-cohorts prompt-rows jobs-per-prompt)
  (define width jobs-per-prompt)
  (let loop ([remaining prompt-rows] [current '()] [used 0] [answer '()])
    (cond
      [(null? remaining)
       (reverse (if (null? current) answer (cons (reverse current) answer)))]
      [(and (null? current) (> width (cohort-width)))
       (loop (cdr remaining) '() 0
             (cons (list (car remaining)) answer))]
      [(> (+ used width) (cohort-width))
       (loop remaining '() 0 (cons (reverse current) answer))]
      [else
       (loop (cdr remaining) (cons (car remaining) current)
             (+ used width) answer)])))

(struct candidate-work (row seed sample-index request) #:transparent)

(define (make-candidate-group row)
  (define compiled (compile-spec backend (hard-program row)))
  (for*/list ([seed (in-list (seeds))]
              [sample-index (in-range (samples-per-seed))])
    (candidate-work
     row seed sample-index
     (generation-request
      compiled (get row 'model_prompt (get row 'prompt))
      #:max-attempts (max-attempts)
      #:temperature (temperature) #:max-tokens (get row 'max_tokens)
      #:seed (+ seed (* 100000 sample-index)) #:deadline-ms (deadline-ms)))))

(define (run-candidates out)
  (define jobs-per-prompt (* (length (seeds)) (samples-per-seed)))
  (for ([row-cohort (in-list (pack-prompt-row-cohorts rows jobs-per-prompt))])
    ;; Compile only the current cohort.  Eagerly compiling all 360 prompts
    ;; duplicates regex vocabularies and defeats the memory benefit of slots.
    (define cohort (append-map make-candidate-group row-cohort))
    (define results
      (generate-batch (map candidate-work-request cohort)))
    (for ([work (in-list cohort)] [result (in-list results)])
      (write-row out
                 (result-json (candidate-work-row work)
                              (candidate-work-seed work)
                              (candidate-work-sample-index work) result)))))

(struct naive-work
  (row seed hard-spec free-spec attempts proposed draws latency found)
  #:mutable #:transparent)

(define (make-naive-group row)
  (define hard-compiled (compile-spec backend (hard-program row)))
  (define free-compiled (compile-spec backend (text (get row 'max_tokens))))
  (for/list ([seed (in-list (seeds))])
    (naive-work row seed hard-compiled free-compiled 0 0 0 0.0 #f)))

(define (naive-request work)
  (define row (naive-work-row work))
  (generation-request
   (naive-work-free-spec work) (get row 'model_prompt (get row 'prompt))
   #:max-attempts 1
   #:temperature (temperature) #:max-tokens (get row 'max_tokens)
   #:seed (+ (* (naive-work-seed work) 100000) (naive-work-attempts work))
   #:deadline-ms (deadline-ms)))

(define (consume-naive-result! work result)
  (set-naive-work-attempts! work (add1 (naive-work-attempts work)))
  (set-naive-work-proposed!
   work (+ (naive-work-proposed work) (generation-result-proposed-tokens result)))
  (set-naive-work-draws!
   work (+ (naive-work-draws work) (generation-result-model-draws result)))
  (set-naive-work-latency!
   work (+ (naive-work-latency work) (generation-result-latency-ms result)))
  (when (eq? (generation-result-status result) 'found)
    (with-handlers ([exn:fail? (lambda (_exn) (void))])
      (observe-token-ids (naive-work-hard-spec work)
                         (generation-result-token-ids result))
      (set-naive-work-found! work result))))

(define (write-naive-result out work)
  (define row (naive-work-row work))
  (define seed (naive-work-seed work))
  (define found (naive-work-found work))
  (write-row
   out
   (if found
       (hash-set*
        (result-json row seed 0 found)
        'method "naive_rejection"
        'attempts (naive-work-attempts work)
        'rejected_attempts (sub1 (naive-work-attempts work))
        'proposed_tokens (naive-work-proposed work)
        'model_draws (naive-work-draws work) 'trie_nodes 0
        'latency_ms (naive-work-latency work))
       (hash
        'prompt_id (get row 'id) 'family (get row 'family)
        'split (get row 'split) 'seed seed 'sample_index 0
        'temperature (temperature) 'method "naive_rejection"
        'status "not-found-attempt-budget" 'reason "naive rejection exhausted"
        'text "" 'token_ids '() 'token_count 0 'lm_logprob #f
        'hard_valid #f 'latency_ms (naive-work-latency work) 'posterior #f
        'tokenizer_fingerprint "" 'artifact_schema_version 2
        'runtime_fingerprint (runtime-fingerprint)
        'attempts (naive-work-attempts work)
        'rejected_attempts (naive-work-attempts work)
        'proposed_tokens (naive-work-proposed work)
        'model_draws (naive-work-draws work) 'trie_nodes 0))))

(define (run-naive out)
  (define jobs-per-prompt (length (seeds)))
  (for ([row-cohort (in-list (pack-prompt-row-cohorts rows jobs-per-prompt))])
    (define works (append-map make-naive-group row-cohort))
    ;; Every rejection round is one backend call over all unfinished prompts.
    (let loop ()
      (define active
        (filter (lambda (work)
                  (and (not (naive-work-found work))
                       (< (naive-work-attempts work) (max-attempts))))
                works))
      (unless (null? active)
        (define results (generate-batch (map naive-request active)))
        (for ([work (in-list active)] [result (in-list results)])
          (consume-naive-result! work result))
        (loop)))
    (for ([work (in-list works)])
      (write-naive-result out work))))

(define (model-file family)
  (build-path (models-dir)
              (string-append
               (regexp-replace* #px"[^A-Za-z0-9._-]" family "_")
               ".json")))

(define (candidate-observation compiled candidate)
  (observe-token-ids compiled (get candidate 'token_ids)))

(define (family-rule-ids family persisted)
  (define identities
    (remove-duplicates
     (for/list ([row (in-list persisted)]
                #:when (string=? family (get row 'family)))
       (get row 'rule_ids))))
  (unless (= (length identities) 1)
    (error 'rack-runner "family ~a has ~a ordered rule identities"
           family (length identities)))
  (car identities))
(define (row-rule-ids row) (map (lambda (rule) (get rule 'rule_id)) (get row 'weak_rules '())))
(define (rules-file family) (path-replace-extension (model-file family) ".rules.json"))
(define (write-rule-manifest family ids model)
  (call-with-output-file (rules-file family)
    (lambda (out) (write-json (hash 'family family 'rule_ids ids
                                    'weak_model_fingerprint (weak-model-fingerprint model)) out))
    #:exists 'truncate/replace))
(define (check-rule-manifest family ids)
  (define payload (call-with-input-file (rules-file family) read-json))
  (unless (and (equal? family (get payload 'family)) (equal? ids (get payload 'rule_ids)))
    (error 'rack-runner "ordered rule manifest mismatch for ~a" family)))

(define (run-observe out)
  (unless (candidates-path)
    (error 'rack-runner "observe requires --candidates"))
  (define candidates (read-jsonl (candidates-path)))
  (define candidates-by-prompt (make-hash))
  (for ([candidate (in-list candidates)])
    (hash-update! candidates-by-prompt (get candidate 'prompt_id)
                  (lambda (items) (cons candidate items)) '()))
  (for ([row (in-list rows)])
    (define compiled (compile-spec backend (row-program row)))
    (dynamic-wind
      void
      (lambda ()
        (for ([candidate (in-list (reverse (hash-ref candidates-by-prompt (get row 'id) '())))])
          (if (not (and (string=? "found" (get candidate 'status))
                        (get candidate 'hard_valid)))
              (write-row out
                         (hash 'record_type "observation_skipped"
                               'candidate_id (get candidate 'candidate_id #f)
                               'prompt_id (get row 'id)
                               'family (get row 'family)
                               'split (get row 'split)
                               'message "candidate was not a hard-valid FOUND"))
              (with-handlers ([exn:fail?
                               (lambda (exn)
                                 (write-row out
                                            (hash 'record_type "observe_error"
                                                  'candidate_id (get candidate 'candidate_id #f)
                                                  'prompt_id (get row 'id)
                                                  'family (get row 'family)
                                                  'split (get row 'split)
                                                  'message (exn-message exn))))])
                (define observation (candidate-observation compiled candidate))
                (write-row
                 out
                 (hash 'record_type "observation"
                       'candidate_id (get candidate 'candidate_id #f)
                       'prompt_id (get row 'id)
                       'family (get row 'family)
                       'split (get row 'split)
                       'seed (get candidate 'seed)
                       'temperature (get candidate 'temperature)
                       'sample_index (get candidate 'sample_index)
                       'labels (vector->list observation)
                       'rule_ids (row-rule-ids row)))))))
      (lambda () (void)))))

(define (run-fit-score out)
  (unless (and (candidates-path) (models-dir))
    (error 'rack-runner "fit-score requires persisted --candidates observations and --models-dir"))
  (make-directory* (models-dir))
  (define persisted
    (filter (lambda (row) (string=? "observation" (get row 'record_type "")))
            (read-jsonl (candidates-path))))
  (define families (remove-duplicates (map (lambda (row) (get row 'family)) rows)))
  (define persisted-by-family (make-hash))
  (for ([row (in-list persisted)])
    (hash-update! persisted-by-family (get row 'family) (lambda (values) (cons row values)) '()))
  (for ([family (in-list families)])
    (define family-persisted (reverse (hash-ref persisted-by-family family '())))
    (define rule-ids (family-rule-ids family family-persisted))
    (define labels
      (for/list ([raw (in-list family-persisted)]
                 #:when (string=? "calibration" (get raw 'split)))
        (get raw 'labels)))
    (with-handlers ([exn:fail?
                     (lambda (exn)
                       (write-row out
                                  (hash 'record_type "fit_error"
                                        'family family
                                        'message (exn-message exn))))])
      (define weak-model (fit-weak-model labels #:seed 0))
      (save-weak-model weak-model (model-file family))
      (write-rule-manifest family rule-ids weak-model)
      (write-row out
                 (hash 'record_type "fit"
                       'family family
                       'weak_model_fingerprint (weak-model-fingerprint weak-model)
                       'diagnostics (weak-model-diagnostics weak-model)))
      (for ([raw (in-list family-persisted)])
        (define observation (get raw 'labels))
        (write-row
         out
         (hash
          'record_type "score"
          'prompt_id (get raw 'prompt_id)
          'family family
          'split (get raw 'split)
          'seed (get raw 'seed)
          'temperature (get raw 'temperature 1.0)
          'sample_index (get raw 'sample_index)
          'candidate_id (get raw 'candidate_id #f)
          'labels observation
          'rule_ids (get raw 'rule_ids)
          'posterior (weak-posterior weak-model observation)
          'weak_model_fingerprint (weak-model-fingerprint weak-model)))))))

(struct pwsg-work (row seed checkpoint request) #:transparent)

(define (run-pwsg out)
  (unless (models-dir)
    (error 'rack-runner "pwsg requires --models-dir"))
  (define weak-models
    (for/hash ([family (in-list
                        (remove-duplicates
                         (map (lambda (row) (get row 'family)) rows)))]
               #:when (file-exists? (model-file family)))
      (values family (load-weak-model (model-file family)))))
  (define valid-rows
    (for/list ([row (in-list rows)]
               #:when
               (let ([available? (file-exists? (model-file (get row 'family)))])
                 (unless available?
                   (write-row out
                              (hash 'record_type "generation_error"
                                    'prompt_id (get row 'id)
                                    'family (get row 'family)
                                    'message "weak model unavailable")))
                 available?))
      row))
  (define checkpoint-budgets
    (if (null? (attempt-checkpoints))
        (list (max-attempts))
        (attempt-checkpoints)))
  (define (make-pwsg-group row)
    (define family (get row 'family))
    (define weak-model (hash-ref weak-models family))
    (check-rule-manifest family (row-rule-ids row))
    (define compiled (compile-spec backend (row-program row)))
    (for*/list ([seed (in-list (seeds))]
                [budget (in-list checkpoint-budgets)])
      (pwsg-work
       row seed budget
       (generation-request
        compiled (get row 'model_prompt (get row 'prompt))
        #:max-attempts budget
        #:max-model-draws (* budget (add1 (get row 'max_tokens)))
        #:weak-model weak-model
        #:temperature (temperature) #:max-tokens (get row 'max_tokens)
        #:seed seed #:deadline-ms (deadline-ms)))))
  (define jobs-per-prompt (* (length (seeds)) (length checkpoint-budgets)))
  (for ([row-cohort
         (in-list (pack-prompt-row-cohorts valid-rows jobs-per-prompt))])
    (define cohort (append-map make-pwsg-group row-cohort))
    (define results (generate-batch (map pwsg-work-request cohort)))
    (for ([work (in-list cohort)] [result (in-list results)])
      (write-row out
                 (hash-set*
                  (result-json (pwsg-work-row work)
                               (pwsg-work-seed work) 0 result)
                  'record_type "pwsg"
                  'checkpoint_budget (pwsg-work-checkpoint work))))))

(define (run-score out)
  (unless (and (candidates-path) (models-dir))
    (error 'rack-runner "score requires persisted --candidates observations and --models-dir"))
  (define persisted
    (filter (lambda (row) (string=? "observation" (get row 'record_type "")))
            (read-jsonl (candidates-path))))
  (for ([family (in-list (remove-duplicates (map (lambda (row) (get row 'family)) rows)))])
    (define rule-ids (family-rule-ids family persisted))
    (define model-file-path (model-file family))
    (if (not (file-exists? model-file-path))
        (write-row out
                   (hash 'record_type "score_error" 'prompt_id #f
                         'family family 'message "weak model unavailable"))
        (let ([weak-model (load-weak-model model-file-path)])
          (check-rule-manifest family rule-ids)
          (for ([raw (in-list persisted)]
                #:when (string=? family (get raw 'family)))
            (define observation (get raw 'labels))
            (write-row
             out
             (hash 'record_type "score"
                   'candidate_id (get raw 'candidate_id #f)
                   'prompt_id (get raw 'prompt_id)
                   'family family
                   'split (get raw 'split)
                   'seed (get raw 'seed)
                   'sample_index (get raw 'sample_index)
                   'labels observation
                   'rule_ids (get raw 'rule_ids)
                   'posterior (weak-posterior weak-model observation)
                   'weak_model_fingerprint (weak-model-fingerprint weak-model))))))))

(make-directory* (or (path-only (output-path)) "."))
(call-with-output-file (output-path)
  (lambda (out)
    (case (string->symbol (mode))
      [(candidates) (run-candidates out)]
      [(naive) (run-naive out)]
      [(observe) (run-observe out)]
      [(fit-score) (run-fit-score out)]
      [(score) (run-score out)]
      [(pwsg) (run-pwsg out)]
      [else (error 'rack-runner "unknown mode ~a" (mode))]))
  #:exists 'truncate/replace)
(when backend (backend-close! backend))
