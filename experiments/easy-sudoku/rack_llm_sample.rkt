#lang racket

(require json
         rack-llm
         rack-llm/backends/llama-cpp)

(define request (read-json))
(define system-prompt (hash-ref request 'system_prompt))
(define user-prompt (hash-ref request 'user_prompt))
(define answer-length (hash-ref request 'answer_length))
(define variant-count (hash-ref request 'variants))
(random-seed (hash-ref request 'seed))

(define digit
  (select
   (list (lit "1"))
   (for/list ([value (in-range 2 5)])
     (list (lit (number->string value))))))

(define answer
  (append
   (list (lit " ["))
   (apply append
          (for/list ([index (in-range answer-length)])
            (if (zero? index)
                (list digit)
                (list (lit ",") digit))))
   (list (lit "]"))))

(define base-oracle
  (make-llama-cpp-llm
   #:server-url (hash-ref request 'server_url)
   #:n-probs (hash-ref request 'n_probs)
   #:temperature (hash-ref request 'temperature)))

(define oracle-calls 0)

(define (oracle transcript prefix)
  (set! oracle-calls (add1 oracle-calls))
  (define candidates
    (filter
     (lambda (candidate)
       (not (string=? (token-candidate-text candidate) "")))
     (base-oracle transcript prefix)))
  (when (getenv "RACK_LLM_SUDOKU_DEBUG")
    (eprintf "oracle prefix=~s candidates=~s\n"
             prefix
             (map token-candidate-text candidates))
    (flush-output (current-error-port)))
  candidates)

(define variants
  (eval oracle
        (list
         (system (lit system-prompt))
         (user (lit user-prompt))
         (apply assistant answer))))

(define outputs
  (for/list ([variant variants]
             [_ (in-range variant-count)])
    (define output (message->string (third variant)))
    (eprintf "rack-llm candidate: ~a\n" output)
    (flush-output (current-error-port))
    output))

(write-json (hash 'outputs outputs
                  'oracle_calls oracle-calls))
(newline)
