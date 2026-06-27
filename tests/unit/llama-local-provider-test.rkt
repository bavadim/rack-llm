#lang racket/base

(require net/base64
         rackunit
         rack-llm
         rack-llm/providers/llama-local-provider
         rack-llm/providers/provider-v2)

(define (fake-sidecar)
  (llama-sidecar
   (lambda (payload)
     (case (hash-ref payload 'op)
       [("load")
        (hash 'ok #t
              'session "s1"
              'vocab_size 5
              'model_id "fake.gguf"
              'model_hash "abc123")]
       [("tokenize")
        (hash 'ok #t
              'tokens
              (for/list ([ch (in-string (hash-ref payload 'text))])
                (case ch
                  [(#\a) 0]
                  [(#\b) 1]
                  [(#\c) 2]
                  [else 4])))]
       [("detokenize")
        (hash 'ok #t
              'text
              (apply string-append
                     (for/list ([id (in-list (hash-ref payload 'tokens))])
                       (vector-ref '#("a" "b" "c" "d" "?") id))))]
       [("next_logits")
        (hash 'ok #t
              'session (hash-ref payload 'session)
              'vocab_size 5
              'logits '(0.0 -1.0 -2.0 -3.0 -4.0)
              'elapsed_ms 1.25
              'prompt_tokens 3
              'prefix_tokens 2
              'cache_hit #t)]
       [else (hash 'ok #f 'error "unknown op")]))
   void))

(define (logits->b64 xs)
  (define out (open-output-bytes))
  (for ([x (in-list xs)])
    (write-bytes (real->floating-point-bytes x 8 #t) out))
  (bytes->string/utf-8 (base64-encode (get-output-bytes out) #"")))

(define llama-local-provider-tests
  (test-suite
   "llama local provider"

   (test-case "fake sidecar provider exposes exact full-vocab logits"
     (define p
       (make-llama-sidecar-provider
        #:model-path "fake.gguf"
        #:process (fake-sidecar)))
     (check-equal? (provider-info-mode (provider-info p)) 'exact-full-vocab)
     (check-equal? (provider-info-model-id (provider-info p)) "fake.gguf")
     (check-equal? (provider-info-model-hash (provider-info p)) "abc123")
     (check-equal? (provider-info-vocab-size (provider-info p)) 5)
     (check-equal? ((provider-tokenize p) "ab") '(0 1))
     (check-equal? ((provider-detokenize p) '(0 1 2)) "abc")

     (define r
       ((provider-next-logits p)
        (list (message 'user (list (lit "hi"))))
        "ab"
        (provider-initial-state p)))
     (check-equal? (vector-length (logits-result-logits r)) 5)
     (check-equal? (vector-ref (logits-result-logits r) 0) 0.0)
     (check-equal? (provider-trace-prefix-tokens (logits-result-trace r)) 2)
     (check-equal? (provider-trace-cache-hit? (logits-result-trace r)) #t))

   (test-case "decode logits response supports base64 float64 payload"
     (define decoded
       (decode-logits-response
        (hash 'ok #t
              'vocab_size 3
              'logits_b64 (logits->b64 '(1.5 -2.0 0.25)))))
     (check-equal? (vector->list (decoded-logits-response-logits decoded))
                   '(1.5 -2.0 0.25)))

   (test-case "decode logits response rejects malformed payload"
     (check-exn
      #rx"logits length"
      (lambda ()
        (decode-logits-response
         (hash 'ok #t
               'vocab_size 2
               'logits '(0.0))))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests llama-local-provider-tests))
