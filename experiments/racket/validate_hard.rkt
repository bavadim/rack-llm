#lang racket/base

(require json racket/cmdline racket/list racket/string rack-llm rack-llm/backend)

(define input-path (make-parameter #f))
(define output-path (make-parameter #f))
(command-line
 #:once-each
 [("--input") value "JSONL requests" (input-path value)]
 [("--output") value "JSONL results" (output-path value)])
(unless (and (input-path) (output-path))
  (error 'validate-hard "--input and --output are required"))

(define rows
  (call-with-input-file (input-path)
    (lambda (in)
      (for/list ([line (in-lines in)] #:unless (string=? "" (string-trim line)))
        (string->jsexpr line)))))
(define characters
  (remove-duplicates
   (cons "\u0000"
         (append-map (lambda (row) (map string (string->list (hash-ref row 'text)))) rows))))
(define pieces (list->vector characters))
(define ids (for/hash ([piece (in-vector pieces)] [id (in-naturals)]) (values piece id)))
(define tokenizer
  (make-tokenizer
   #:vocab-size (vector-length pieces)
   #:fingerprint "validate-hard-unicode-scalar-v1"
   #:token-ref (lambda (id) (vector-ref pieces id))
   #:tokenize (lambda (value) (map (lambda (char) (hash-ref ids (string char)))
                                  (string->list value)))
   #:detokenize (lambda (tokens)
                  (apply string-append (map (lambda (id) (vector-ref pieces id)) tokens)))))
(define provider
  (make-provider
   #:vocab-size (vector-length pieces) #:eog-token-ids '(0) #:cohort-width 1
   #:open-cohort (lambda (_prompts) (error 'validate-hard "generation is unavailable"))
   #:restore-lanes! void #:sample-factors void #:decode! void #:close-cohort! void))
(define backend (make-backend tokenizer provider void))
(define (program hard)
  (case (string->symbol (hash-ref hard 'kind))
    [(literal) (lit (hash-ref hard 'value))]
    [(choice) (apply choice (map lit (hash-ref hard 'values)))]
    [(ere) (ere (hash-ref hard 'pattern))]
    [else (error 'validate-hard "unsupported hard kind ~a" (hash-ref hard 'kind))]))

(call-with-output-file (output-path)
  (lambda (out)
    (for ([row (in-list rows)])
      (with-handlers ([exn:fail? (lambda (exn)
                                   (write-json (hash 'error (exn-message exn)) out)
                                   (newline out))])
        (write-json
         (hash 'valid (accepts? (compile-spec backend (program (hash-ref row 'hard_spec)))
                                (hash-ref row 'text)))
         out)
        (newline out))))
  #:exists 'truncate/replace)
(backend-close! backend)
