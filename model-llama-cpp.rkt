#lang racket/base

(require ffi/unsafe
         racket/list
         racket/runtime-path
         (only-in "private/domain.rkt" domain-include? domain-ids)
         (only-in "private/model.rkt"
                  tokenizer provider model
                  factor-selection
                  factor-request-temperature factor-request-domain
                  factor-request-constrain? factor-request-children
                  factor-request-draw))

(provide llama-cpp-backend)

(define-runtime-path default-native-lib "native/llama/build/librackllm_llama.so")

(struct native-api
  (model-open model-close vocab-size vocab-fingerprint eog-count eog-ref tokenize detokenize token->piece
              cohort-open cohort-close cohort-start cohort-reset cohort-decode
              cohort-sample-factors cohort-end)
  #:transparent)
(struct native-cohort (engine scratch) #:transparent)
(struct reusable-buffer (pointer capacity) #:transparent)

(define api-cache (make-hash))

(define (llama-cpp-backend #:model-path model-path
                         #:cohort-width cohort-width
                         #:context-per-lane context-per-lane
                         #:native-lib [native-lib-path (getenv "RACK_LLM_LLAMA_NATIVE_LIB")]
                         #:threads [threads 1]
                         #:batch-size [batch-size 8192]
                         #:ubatch-size [ubatch-size 512]
                         #:batch-threads [batch-threads 16]
                         #:factor-threads [factor-threads 16]
                         #:gpu-layers [gpu-layers -1]
                         #:vocab-only? [vocab-only? #f])
  (unless (and (exact-positive-integer? cohort-width) (<= cohort-width 32))
    (raise-argument-error 'llama-cpp-backend "cohort width in [1,32]" cohort-width))
  (unless (exact-positive-integer? context-per-lane)
    (raise-argument-error 'llama-cpp-backend
                          "exact-positive-integer? context-per-lane" context-per-lane))
  (define api (load-native-api native-lib-path))
  (define path-string
    (path->string (if (path? model-path) model-path (string->path model-path))))
  (define handle
    (call/native-error
     'llama-cpp-backend
     (lambda (err err-len)
       ((native-api-model-open api) path-string gpu-layers
                                    (if vocab-only? 1 0) err err-len))))
  (define size ((native-api-vocab-size api) handle))
  (define fingerprint-hex
    (number->string ((native-api-vocab-fingerprint api) handle) 16))
  (define vocab-fingerprint
    (string-append "llama-vocab-fnv1a64:"
                   (make-string (- 16 (string-length fingerprint-hex)) #\0)
                   fingerprint-hex))
  (define eog-token-ids
    (for/list ([i (in-range ((native-api-eog-count api) handle))])
      ((native-api-eog-ref api) handle i)))
  (define engine-box (box #f))
  (define active-box (box #f))
  (define (open-engine!)
    (when vocab-only?
      (error 'llama-cpp-open-cohort "vocabulary-only model cannot generate"))
    (or (unbox engine-box)
        (let ([engine
               (call/native-error
                'llama-cpp-open-cohort
                (lambda (err err-len)
                  ((native-api-cohort-open api)
                   handle cohort-width context-per-lane batch-size ubatch-size
                   threads batch-threads factor-threads err err-len)))])
          (set-box! engine-box engine)
          engine)))
  (define tok
    (tokenizer
     #:vocab-size size
     #:fingerprint vocab-fingerprint
     #:token-ref (lambda (id) (native-token->piece api handle id))
     #:tokenize (lambda (text) (native-tokenize api handle text))
     #:detokenize (lambda (ids) (native-detokenize api handle ids))))
  (define llm-provider
    (provider
     #:vocab-size size
     #:eog-token-ids eog-token-ids
     #:cohort-width cohort-width
     #:context-limit context-per-lane
     #:open-cohort
     (lambda (prompts)
       (when (unbox active-box)
         (error 'llama-cpp-open-cohort "backend already has an active cohort"))
       (define engine (open-engine!))
       (with-handlers ([exn:fail?
                        (lambda (error)
                          ;; batch_start can fail after partially mutating the
                          ;; context.  Never retain such an engine.
                          ((native-api-cohort-close api) engine)
                          (set-box! engine-box #f)
                          (raise error))])
         (native-cohort-start! api engine prompts))
       (define cohort (native-cohort engine (make-hasheq)))
       (set-box! active-box cohort)
       cohort)
     #:restore-lanes!
     (lambda (cohort lanes)
       (check-active-cohort 'llama-cpp-restore-lanes! active-box cohort)
       (call/native-error
        'llama-cpp-restore-lanes!
        (lambda (err err-len)
          (zero? ((native-api-cohort-reset api)
                  (native-cohort-engine cohort)
                  (cohort-buffer/fill! cohort 'reset-lanes _int32 lanes)
                  (length lanes) err err-len)))))
     #:sample-factors
     (lambda (cohort entries)
       (check-active-cohort 'llama-cpp-sample-factors active-box cohort)
       (native-cohort-sample-factors api cohort entries))
     #:decode!
     (lambda (cohort tokens)
       (check-active-cohort 'llama-cpp-decode! active-box cohort)
       (call/native-error
        'llama-cpp-decode!
        (lambda (err err-len)
          (zero? ((native-api-cohort-decode api)
                  (native-cohort-engine cohort)
                  (cohort-buffer/fill! cohort 'decode-tokens _int32 tokens)
                  err err-len)))))
     #:close-cohort!
     (lambda (cohort poisoned?)
       (check-active-cohort 'llama-cpp-close-cohort! active-box cohort)
       (dynamic-wind
         void
         (lambda ()
           (cond
             [poisoned?
              ;; A failed llama_decode may have partially mutated KV/recurrent
              ;; state.  Destroy the context; the next cohort creates a clean one.
              ((native-api-cohort-close api) (native-cohort-engine cohort))
              (set-box! engine-box #f)]
             [else
              (unless (zero? ((native-api-cohort-end api)
                              (native-cohort-engine cohort)))
                ;; End failure also quarantines the context.
                ((native-api-cohort-close api) (native-cohort-engine cohort))
                (set-box! engine-box #f)
                (error 'llama-cpp-close-cohort! "native cohort release failed"))]))
         (lambda () (set-box! active-box #f))))))
  (model
   tok llm-provider
   (lambda ()
     (when (unbox active-box)
       (error 'backend-close! "llama backend still has an active cohort"))
     (when (unbox engine-box)
       ((native-api-cohort-close api) (unbox engine-box))
       (set-box! engine-box #f))
     ((native-api-model-close api) handle))))

(define (check-active-cohort who active-box cohort)
  (unless (and (native-cohort? cohort) (eq? cohort (unbox active-box)))
    (error who "stale or foreign cohort handle")))

(define (load-native-api override)
  (define key (or override 'default))
  (hash-ref api-cache key
            (lambda ()
              (define api (open-native-api override))
              (hash-set! api-cache key api)
              api)))

(define (open-native-api override)
  (define lib (open-native-lib override))
  (define (ffi name type) (get-ffi-obj name lib type))
  (native-api
   (ffi "rackllm_llama_model_open"
        (_fun _string _int32 _int32 _bytes _size -> _pointer))
   (ffi "rackllm_llama_model_close" (_fun _pointer -> _void))
   (ffi "rackllm_llama_vocab_size" (_fun _pointer -> _int32))
   (ffi "rackllm_llama_vocab_fingerprint" (_fun _pointer -> _uint64))
   (ffi "rackllm_llama_eog_count" (_fun _pointer -> _int32))
   (ffi "rackllm_llama_eog_ref" (_fun _pointer _int32 -> _int32))
   (ffi "rackllm_llama_tokenize" (_fun _pointer _bytes _int32 _pointer _int32 -> _int32))
   (ffi "rackllm_llama_detokenize" (_fun _pointer _pointer _int32 _bytes _int32 -> _int32))
   (ffi "rackllm_llama_token_to_piece" (_fun _pointer _int32 _bytes _int32 -> _int32))
   (ffi "rackllm_llama_batch_engine_open"
        (_fun _pointer _int32 _int32 _int32 _int32 _int32 _int32 _int32
              _bytes _size -> _pointer))
   (ffi "rackllm_llama_batch_engine_close" (_fun _pointer -> _void))
   (ffi "rackllm_llama_batch_start"
        (_fun _pointer _pointer _pointer _bytes _size -> _int32))
   (ffi "rackllm_llama_batch_reset"
        (_fun _pointer _pointer _int32 _bytes _size -> _int32))
   (ffi "rackllm_llama_batch_commit"
        (_fun _pointer _pointer _bytes _size -> _int32))
   (ffi "rackllm_llama_batch_sample_factors"
        (_fun _pointer _pointer _pointer _pointer _pointer _pointer _pointer
              _pointer _pointer _pointer _pointer _int32 _pointer _pointer _pointer
              -> _int32))
   (ffi "rackllm_llama_batch_end" (_fun _pointer -> _int32))))

(define (open-native-lib override)
  (define candidates
    (if override
        (list override)
        (list (path->string default-native-lib) "rackllm_llama" "librackllm_llama")))
  (let loop ([remaining candidates] [errors '()])
    (cond
      [(null? remaining)
       (error 'llama-cpp-backend
              "cannot load native llama.cpp shim; run `make native-llama` or set RACK_LLM_LLAMA_NATIVE_LIB; tried ~a; errors: ~a"
              candidates (reverse errors))]
      [else
       (define candidate (car remaining))
       (with-handlers ([exn:fail?
                        (lambda (exn)
                          (loop (cdr remaining)
                                (cons (format "~a: ~a" candidate (exn-message exn)) errors)))])
         (ffi-lib candidate))])))

(define (make-int32-buffer ids)
  (define ptr (malloc _int32 (max 1 (length ids)) 'atomic-interior))
  (for ([id (in-list ids)] [i (in-naturals)]) (ptr-set! ptr _int32 i id))
  ptr)

(define (cohort-buffer cohort key type capacity)
  (define required (max 1 capacity))
  (define scratch (native-cohort-scratch cohort))
  (define buffer (hash-ref scratch key #f))
  (cond
    [(and buffer (>= (reusable-buffer-capacity buffer) required))
     (reusable-buffer-pointer buffer)]
    [else
     (define next (reusable-buffer (malloc type required 'atomic-interior) required))
     (hash-set! scratch key next)
     (reusable-buffer-pointer next)]))

(define (cohort-buffer/fill! cohort key type values)
  (define ptr (cohort-buffer cohort key type (length values)))
  (for ([value (in-list values)] [i (in-naturals)])
    (ptr-set! ptr type i value))
  ptr)

(define (prefix-offsets counts)
  (let loop ([remaining counts] [total 0] [answer '(0)])
    (if (null? remaining)
        (reverse answer)
        (let ([next (+ total (car remaining))])
          (loop (cdr remaining) next (cons next answer))))))

(define (native-cohort-start! api engine prompts)
  (define counts (map length prompts))
  (define flat (append* prompts))
  (call/native-error
   'llama-cpp-open-cohort
   (lambda (err err-len)
     (zero? ((native-api-cohort-start api) engine
             (make-int32-buffer flat) (make-int32-buffer (prefix-offsets counts))
             err err-len)))))

(define (native-cohort-sample-factors api cohort entries)
  (define engine (native-cohort-engine cohort))
  (define lanes (map car entries))
  (define requests (map cdr entries))
  (define temperatures (map factor-request-temperature requests))
  (define domains (map factor-request-domain requests))
  (define domain-lists
    (map (lambda (domain) (vector->list (domain-ids domain))) domains))
  (define flat-domain (append* domain-lists))
  (define domain-offsets (prefix-offsets (map length domain-lists)))
  (define domain-includes (map (lambda (d) (if (domain-include? d) 1 0)) domains))
  (define constrains (map (lambda (r) (if (factor-request-constrain? r) 1 0)) requests))
  (define child-lists (map factor-request-children requests))
  (define flat-children (append* child-lists))
  (define child-offsets (prefix-offsets (map length child-lists)))
  (define draws (map factor-request-draw requests))
  (define count (length entries))
  (define out-ids (cohort-buffer cohort 'factor-out-ids _int32 count))
  (define out-metrics (cohort-buffer cohort 'factor-out-metrics _double (* 3 count)))
  (define out-counts (cohort-buffer cohort 'factor-out-counts _int32 count))
  (define status
    ((native-api-cohort-sample-factors api)
     engine
     (cohort-buffer/fill! cohort 'factor-lanes _int32 lanes)
     (cohort-buffer/fill! cohort 'factor-temperatures _double temperatures)
     (cohort-buffer/fill! cohort 'factor-domain-includes _int32 domain-includes)
     (cohort-buffer/fill! cohort 'factor-domain-offsets _int32 domain-offsets)
     (cohort-buffer/fill! cohort 'factor-domain-ids _int32 flat-domain)
     (cohort-buffer/fill! cohort 'factor-constrains _int32 constrains)
     (cohort-buffer/fill! cohort 'factor-child-offsets _int32 child-offsets)
     (cohort-buffer/fill! cohort 'factor-child-ids _int32 (map car flat-children))
     (cohort-buffer/fill! cohort 'factor-child-masses _double (map cdr flat-children))
     (cohort-buffer/fill! cohort 'factor-draws _double draws)
     count out-ids out-metrics out-counts))
  (unless (zero? status)
    (error 'llama-cpp-sample-factors "native factor batch failed"))
  (for/list ([index (in-range count)])
    (define candidates (ptr-ref out-counts _int32 index))
    (cond
      [(= candidates -1) #f]
      [(negative? candidates)
       (error 'llama-cpp-sample-factors
              "native lane ~a factor scan failed" (list-ref lanes index))]
      [else
       (factor-selection
        (ptr-ref out-ids _int32 index)
        (ptr-ref out-metrics _double (* 3 index))
        (ptr-ref out-metrics _double (+ (* 3 index) 1))
        (ptr-ref out-metrics _double (+ (* 3 index) 2)))])))

(define (native-tokenize api handle text)
  (define bytes (string->bytes/utf-8 text))
  (define needed ((native-api-tokenize api) handle bytes (bytes-length bytes) #f 0))
  (when (negative? needed) (error 'llama-cpp-tokenize "native tokenizer failed"))
  (define out (malloc _int32 (max 1 needed) 'atomic-interior))
  (define count ((native-api-tokenize api) handle bytes (bytes-length bytes) out needed))
  (unless (= count needed)
    (error 'llama-cpp-tokenize "sizing returned ~a, tokenization returned ~a" needed count))
  (for/list ([i (in-range count)]) (ptr-ref out _int32 i)))

(define (native-detokenize api handle ids)
  (define token-ptr (make-int32-buffer ids))
  (define needed (abs ((native-api-detokenize api) handle token-ptr (length ids) #f 0)))
  (define out (make-bytes (max 1 needed)))
  (define count ((native-api-detokenize api) handle token-ptr (length ids)
                 out (bytes-length out)))
  (when (negative? count) (error 'llama-cpp-detokenize "native detokenizer failed"))
  (bytes->string/utf-8 (subbytes out 0 count) #\uFFFD))

(define (native-token->piece api handle id)
  (define needed (abs ((native-api-token->piece api) handle id #f 0)))
  (define out (make-bytes (max 1 needed)))
  (define count ((native-api-token->piece api) handle id out (bytes-length out)))
  (when (negative? count) (error 'llama-cpp-token-ref "native token->piece failed"))
  (bytes->string/utf-8 (subbytes out 0 count) #\uFFFD))

(define (call/native-error who thunk)
  (define err (make-bytes 4096 0))
  (define value (thunk err (bytes-length err)))
  (if value value (error who "~a" (cstring-bytes->string err))))

(define (cstring-bytes->string bytes)
  (define len
    (or (for/first ([i (in-range (bytes-length bytes))]
                    #:when (zero? (bytes-ref bytes i))) i)
        (bytes-length bytes)))
  (define text (bytes->string/utf-8 (subbytes bytes 0 len) #\uFFFD))
  (if (string=? text "") "native llama.cpp call failed" text))
