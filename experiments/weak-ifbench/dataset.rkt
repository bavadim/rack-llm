#lang racket/base

(require json
         racket/file
         racket/port
         racket/system)

(provide (struct-out ifbench-task)
         (struct-out constraint-spec)
         (struct-out gold-verdict)
         load-ifbench-jsonl
         run-gold-verifier)

(struct ifbench-task
  (id
   prompt
   constraints
   gold-verifier-id
   metadata)
  #:transparent)

(struct constraint-spec
  (id
   type
   params)
  #:transparent)

(struct gold-verdict
  (prompt-passed?
   constraint-results
   message)
  #:transparent)

(define (load-ifbench-jsonl path)
  (call-with-input-file path
    (lambda (in)
      (let loop ([tasks '()])
        (define line (read-line in 'any))
        (cond
          [(eof-object? line) (reverse tasks)]
          [(string=? line "") (loop tasks)]
          [else (loop (cons (json->ifbench-task (string->jsexpr line))
                            tasks))])))))

(define (run-gold-verifier task candidate)
  (define metadata (ifbench-task-metadata task))
  (define command (hash-ref metadata 'verifier_command #f))
  (cond
    [(string? command) (run-command-gold-verifier task candidate command)]
    [else (run-embedded-gold-verifier task candidate)]))

(define (json->ifbench-task js)
  (unless (hash? js)
    (error 'load-ifbench-jsonl "expected JSON object: ~e" js))
  (ifbench-task
   (required-string js 'id)
   (required-string js 'prompt)
   (map json->constraint-spec (hash-ref js 'constraints '()))
   (->symbol (hash-ref js 'gold_verifier_id 'embedded))
   (json-object-or-empty (hash-ref js 'metadata (hash)))))

(define (json->constraint-spec js)
  (unless (hash? js)
    (error 'load-ifbench-jsonl "expected constraint object: ~e" js))
  (constraint-spec
   (->symbol (hash-ref js 'id))
   (->symbol (hash-ref js 'type))
   (json-object-or-empty (hash-ref js 'params (hash)))))

(define (run-embedded-gold-verifier task candidate)
  (define metadata (ifbench-task-metadata task))
  (define fake-substring (hash-ref metadata 'fake_gold_substring #f))
  (define explicit-prompt-pass?
    (and (string? fake-substring) (contains-literal? candidate fake-substring)))
  (define constraint-results
    (for/hash ([constraint (in-list (ifbench-task-constraints task))])
      (define constraint-id (constraint-spec-id constraint))
      (define expected
        (hash-ref/key (hash-ref metadata 'fake_constraint_substrings (hash))
                      constraint-id
                      #f))
      (values constraint-id
              (if (string? expected)
                  (contains-literal? candidate expected)
                  explicit-prompt-pass?))))
  (define prompt-passed?
    (if (string? fake-substring)
        explicit-prompt-pass?
        (andmap values (hash-values constraint-results))))
  (gold-verdict prompt-passed?
                constraint-results
                (if prompt-passed? #f "candidate failed embedded verifier")))

(define (run-command-gold-verifier task candidate command)
  (define candidate-path (make-temporary-file "rack-llm-ifbench-candidate-~a.txt"))
  (dynamic-wind
   (lambda () (void))
   (lambda ()
     (call-with-output-file candidate-path
       (lambda (out) (display candidate out))
       #:exists 'truncate)
     (define output
       (with-output-to-string
         (lambda ()
           (unless (system* command
                            "--task-id"
                            (ifbench-task-id task)
                            "--candidate-file"
                            (path->string candidate-path))
             (error 'run-gold-verifier
                    "verifier command failed for task ~a"
                    (ifbench-task-id task))))))
     (json->gold-verdict (string->jsexpr output)))
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_exn) (void))])
       (delete-file candidate-path)))))

(define (json->gold-verdict js)
  (unless (hash? js)
    (error 'run-gold-verifier "expected verifier JSON object: ~e" js))
  (gold-verdict
   (hash-ref js 'prompt_passed #f)
   (for/hash ([(constraint-id passed?) (in-hash (hash-ref js 'constraint_results (hash)))])
     (values (->symbol constraint-id) (and passed? #t)))
   (let ([message (hash-ref js 'message #f)])
     (and (string? message) message))))

(define (required-string js key)
  (define value (hash-ref js key #f))
  (unless (string? value)
    (error 'load-ifbench-jsonl "expected string field ~a in ~e" key js))
  value)

(define (json-object-or-empty value)
  (if (hash? value) value (hash)))

(define (->symbol value)
  (cond
    [(symbol? value) value]
    [(string? value) (string->symbol value)]
    [else (error 'load-ifbench-jsonl "expected symbol-like value: ~e" value)]))

(define (hash-ref/key table key default)
  (hash-ref table
            key
            (lambda ()
              (if (symbol? key)
                  (hash-ref table (symbol->string key) default)
                  default))))

(define (contains-literal? text piece)
  (and (regexp-match? (regexp (regexp-quote piece)) text) #t))
