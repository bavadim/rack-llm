#lang racket/base

(require racket/list
         racket/runtime-path
         racket/string
         rackunit
         "../main.rkt"
         "../model-qwen.rkt")

(define-runtime-path repo-root "..")

(define default-model-path "/mnt/storage/models/qwen/Qwen3.5-4B")

(define (configured-model-path)
  (or (getenv "RACK_LLM_MODEL_PATH") default-model-path))

(define (configured-sidecar-command model-path)
  (or (getenv "RACK_LLM_LLAMA_SIDECAR")
      (format "~a ~a --model-path ~a"
              (path->string (build-path repo-root ".venv-realbench" "bin" "python"))
              (path->string (build-path repo-root "experiments" "012_real_model_benchmark" "code" "hf_logits_sidecar.py"))
              model-path)))

(define (open-real-backend)
  (define model-path (configured-model-path))
  (define command (configured-sidecar-command model-path))
  (unless (directory-exists? model-path)
    (error 'e2e-real-test
           "real model directory is missing: ~a; set RACK_LLM_MODEL_PATH or run `make realbench-env`"
           model-path))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (error 'e2e-real-test
                            "real sidecar/model backend is required; run `make realbench-env` or set RACK_LLM_MODEL_PATH and RACK_LLM_LLAMA_SIDECAR; backend error: ~a"
                            (exn-message exn)))])
    (qwen-model
     #:model-path model-path
     #:command command
     #:context-size 192
     #:threads 1
     #:seed 0)))

(define (prompt-ids tok text)
  (tokenize tok text))

(define (generated-text tok result)
  (detokenize tok (generation-result-token-ids result)))

(define (check-found result)
  (check-equal? (generation-result-status result) 'found)
  (check-true (generation-result-hard-ok? result)))

(define (generate-text provider tok prompt filter
                       #:beta [beta 1.0]
                       #:lambda [lambda-weight 0.5]
                       #:seed [seed 0]
                       #:max-tokens [max-tokens 8]
                       #:candidate-policy [candidate-policy 'allowed-only])
  (define result
    (generate provider
              (prompt-ids tok prompt)
              filter
              #:beta beta
              #:lambda lambda-weight
              #:temperature 0.7
              #:seed seed
              #:max-tokens max-tokens
              #:candidate-policy candidate-policy))
  (values result (generated-text tok result)))

(define (prefix-of? xs ys)
  (and (<= (length xs) (length ys))
       (equal? xs (take ys (length xs)))))

(define (choose-token-prefix-pair tok)
  (define candidates
    '((" paid" " paid later")
      (" yes" " yes please")
      (" ok" " ok then")
      (" answer" " answer now")
      (" a" " a b")))
  (let loop ([remaining candidates])
    (cond
      [(null? remaining)
       (error 'e2e-real-test
              "could not find a literal pair whose token ids have a prefix relation")]
      [else
       (define pair (car remaining))
       (define short (car pair))
       (define long (cadr pair))
       (if (prefix-of? (tokenize tok short)
                       (tokenize tok long))
           pair
           (loop (cdr remaining)))])))

(module+ test
  (define backend #f)
  (dynamic-wind
    (lambda () (set! backend (open-real-backend)))
    (lambda ()
      (define tok (model-tokenizer backend))
      (define provider (model-provider backend))

      (test-case "hard finite choice returns only an allowed answer"
        (define filter
          (choice
           (list (lit tok " yes")
                 (lit tok " no"))))
        (define-values (result text)
          (generate-text provider tok
                         "Answer yes or no. Reply with one word:"
                         filter
                         #:max-tokens 2))
        (check-found result)
        (check-true (and (member text '(" yes" " no")) #t)))

      (test-case "hard regex generates a compact incident id"
        (define filter (rx tok " INC-[0-9]{3}"))
        (define-values (result text)
          (generate-text provider tok
                         "Create one incident id in the form INC-123:"
                         filter
                         #:max-tokens 8))
        (check-found result)
        (check-regexp-match #px"^ INC-[0-9]{3}$" text))

      (test-case "hard prefix-overlap choice does not stop at the shorter accepted prefix"
        (define pair (choose-token-prefix-pair tok))
        (define short (car pair))
        (define long (cadr pair))
        (define filter
          (choice
           (list (lit tok short)
                 (lit tok long))))
        (define-values (result text)
          (generate-text provider tok
                         (string-append "Reply exactly:" long)
                         filter
                         #:max-tokens 6))
        (check-found result)
        (check-equal? text long))

      (test-case "soft ranked choice can overcome the model-preferred branch"
        (define filter
          (choice
           (list (score 20.0 (lit tok " approve") #f)
                 (lit tok " reject"))))
        (define-values (result text)
          (generate-text provider tok
                         "The request is risky. Reply approve or reject:"
                         filter
                         #:beta 10.0
                         #:max-tokens 2))
        (check-found result)
        (check-equal? text " approve")
        (check-true (> (generation-result-filter-score result) 0.0)))

      (test-case "soft open text veto rejects TODO even when prompted"
        (define filter
          (text
           3
           (list (ban tok " TODO")
                 (ban tok "TODO"))))
        (define-values (result text)
          (generate-text provider tok
                         "Reply with TODO:"
                         filter
                         #:candidate-policy 'full-vocab
                         #:max-tokens 3))
        (check-found result)
        (check-false (string-contains? text "TODO")))

      (test-case "soft open text rank rewards a practical domain term"
        (define preferred " patent")
        (define preferred-token-count (length (tokenize tok preferred)))
        (define filter
          (text
           preferred-token-count
           (list (rank tok 30.0 preferred))))
        (define-values (result text)
          (generate-text provider tok
                         "Write one legal invention keyword:"
                         filter
                         #:candidate-policy 'full-vocab
                         #:beta 10.0
                         #:lambda 10.0
                         #:max-tokens preferred-token-count))
        (check-found result)
        (check-true (string-contains? (string-downcase text) "patent"))
        (check-true (> (generation-result-filter-score result) 0.0))))
    (lambda ()
      (when backend
        ((model-close! backend))))))
