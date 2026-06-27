#lang racket/base

(require json
         racket/string
         rack-llm/experiments/weak-ifbench/dataset
         rack-llm/rules/combinators
         rack-llm/rules/rule)

(provide (struct-out weak-rule-coverage)
         weak-rules-for-constraint
         weak-rules-for-task
         weak-rule-coverage-for-task
         supported-constraint-type?)

(struct weak-rule-coverage
  (supported
   unsupported)
  #:transparent)

(define (weak-rules-for-task task)
  (apply append (map weak-rules-for-constraint (ifbench-task-constraints task))))

(define (weak-rule-coverage-for-task task)
  (define constraints (ifbench-task-constraints task))
  (weak-rule-coverage
   (filter (lambda (constraint)
             (supported-constraint-type? (constraint-spec-type constraint)))
           constraints)
   (filter (lambda (constraint)
             (not (supported-constraint-type? (constraint-spec-type constraint))))
           constraints)))

(define (supported-constraint-type? type)
  (and (memq type
             '(word-count
               sentence-count
               phrase-presence
               forbidden-phrase
               section-header
               header-format
               json-structure
               markdown-structure))
       #t))

(define (weak-rules-for-constraint constraint)
  (case (constraint-spec-type constraint)
    [(word-count)
     (soft-rules (list (make-count-rule constraint
                                         'word-count/split
                                         "weak whitespace word count"
                                         split-word-count)
                       (make-count-rule constraint
                                         'word-count/regex
                                         "weak regex word count"
                                         regex-word-count)))]
    [(sentence-count)
     (soft-rules (list (make-count-rule constraint
                                         'sentence-count/punctuation
                                         "weak punctuation sentence count"
                                         punctuation-sentence-count)
                       (make-count-rule constraint
                                         'sentence-count/newline
                                         "weak newline sentence count"
                                         newline-sentence-count)))]
    [(phrase-presence)
     (soft-rules (list (make-phrase-presence-rule constraint
                                                   'phrase-presence/lowercase
                                                   string-contains-ci?)
                       (make-phrase-presence-rule constraint
                                                   'phrase-presence/raw
                                                   string-contains-literal?)))]
    [(forbidden-phrase)
     (soft-rules (list (make-forbidden-phrase-rule constraint
                                                    'forbidden-phrase/lowercase
                                                    string-contains-ci?)
                       (make-forbidden-phrase-rule constraint
                                                    'forbidden-phrase/word-boundary
                                                    string-contains-word?)))]
    [(section-header header-format)
     (soft-rules (list (make-header-rule constraint
                                          'format/header-prefix
                                          header-prefix?)
                       (make-header-rule constraint
                                          'format/markdown-headings
                                          markdown-heading?)))]
    [(json-structure)
     (soft-rules (list (make-json-parse-rule constraint)
                       (make-json-shape-rule constraint)))]
    [(markdown-structure)
     (soft-rules (list (make-markdown-heading-rule constraint)
                       (make-markdown-list-or-code-rule constraint)))]
    [else '()]))

(define (soft-rules rules)
  (map soft rules))

(define (make-count-rule constraint local-id description counter)
  (rule (constraint-rule-id constraint local-id)
        description
        'candidate
        (lambda (candidate)
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(code-block? candidate) (abstain #:message "code block makes count heuristic unreliable")]
            [else
             (define count (counter candidate))
             (count-verdict count (constraint-spec-params constraint))]))))

(define (count-verdict count params)
  (define exact-count (param-number params '(count target exact) #f))
  (define min-count (param-number params '(min minimum min_count) #f))
  (define max-count (param-number params '(max maximum max_count) #f))
  (define passed?
    (cond
      [(number? exact-count) (= count exact-count)]
      [(and (number? min-count) (number? max-count))
       (and (>= count min-count) (<= count max-count))]
      [(number? min-count) (>= count min-count)]
      [(number? max-count) (<= count max-count)]
      [else #f]))
  (cond
    [(not (or (number? exact-count) (number? min-count) (number? max-count)))
     (abstain #:message "count constraint has no numeric target"
              #:metadata (hash 'count count))]
    [passed? (accept #:metadata (hash 'count count))]
    [else (reject #:message (format "count ~a outside weak bounds" count)
                  #:metadata (hash 'count count))]))

(define (make-phrase-presence-rule constraint local-id contains?)
  (rule (constraint-rule-id constraint local-id)
        "weak phrase presence check"
        'candidate
        (lambda (candidate)
          (define phrase (constraint-phrase constraint))
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(not phrase) (abstain #:message "phrase constraint has no phrase parameter")]
            [(contains? candidate phrase) (accept)]
            [else (reject #:message "required phrase not found")]))))

(define (make-forbidden-phrase-rule constraint local-id contains?)
  (rule (constraint-rule-id constraint local-id)
        "weak forbidden phrase check"
        'candidate
        (lambda (candidate)
          (define phrase (constraint-phrase constraint))
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(not phrase) (abstain #:message "forbidden phrase constraint has no phrase parameter")]
            [(contains? candidate phrase) (reject #:message "forbidden phrase found")]
            [else (accept)]))))

(define (make-header-rule constraint local-id predicate)
  (rule (constraint-rule-id constraint local-id)
        "weak section/header format check"
        'candidate
        (lambda (candidate)
          (define header (constraint-header constraint))
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(not header) (abstain #:message "header constraint has no header parameter")]
            [(predicate candidate header) (accept)]
            [else (reject #:message "expected header not found")]))))

(define (make-json-parse-rule constraint)
  (rule (constraint-rule-id constraint 'json/parse)
        "weak JSON parse check"
        'candidate
        (lambda (candidate)
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [else
             (with-handlers ([exn:fail? (lambda (_exn)
                                          (reject #:message "candidate is not parseable JSON"))])
               (define js (string->jsexpr candidate))
               (if (json-root-matches? js (constraint-root constraint))
                   (accept)
                   (reject #:message "JSON root shape mismatch")))]))))

(define (make-json-shape-rule constraint)
  (rule (constraint-rule-id constraint 'json/braces)
        "weak JSON delimiter shape check"
        'candidate
        (lambda (candidate)
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [else
             (define trimmed (string-trim candidate))
             (case (constraint-root constraint)
               [(array) (if (and (string-prefix? trimmed "[")
                                 (string-suffix? trimmed "]"))
                            (accept)
                            (reject #:message "JSON array delimiters missing"))]
               [else (if (and (string-prefix? trimmed "{")
                              (string-suffix? trimmed "}"))
                         (accept)
                         (reject #:message "JSON object delimiters missing"))])]))))

(define (make-markdown-heading-rule constraint)
  (rule (constraint-rule-id constraint 'markdown/headings)
        "weak Markdown heading check"
        'candidate
        (lambda (candidate)
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(regexp-match? #px"(?m:^#{1,6}[[:space:]]+\\S)" candidate) (accept)]
            [else (reject #:message "Markdown heading not found")]))))

(define (make-markdown-list-or-code-rule constraint)
  (rule (constraint-rule-id constraint 'markdown/list-or-code)
        "weak Markdown list or code block check"
        'candidate
        (lambda (candidate)
          (cond
            [(not (string? candidate)) (abstain #:message "candidate is not a string")]
            [(or (regexp-match? #px"(?m:^([*-]|[0-9]+\\.)[[:space:]]+\\S)" candidate)
                 (code-block? candidate))
             (accept)]
            [else (reject #:message "Markdown list or code block not found")]))))

(define (constraint-rule-id constraint local-id)
  (define constraint-id (constraint-spec-id constraint))
  (if (eq? constraint-id (constraint-spec-type constraint))
      local-id
      (string->symbol (format "~a/~a" constraint-id local-id))))

(define (constraint-phrase constraint)
  (define params (constraint-spec-params constraint))
  (param-string params '(phrase text value) #f))

(define (constraint-header constraint)
  (define params (constraint-spec-params constraint))
  (param-string params '(header section title value) #f))

(define (constraint-root constraint)
  (->symbol/default (hash-ref/key (constraint-spec-params constraint) 'root 'object)
                    'object))

(define (json-root-matches? js root)
  (case root
    [(array) (list? js)]
    [(object) (hash? js)]
    [else #t]))

(define (split-word-count text)
  (length (filter (lambda (piece) (not (string=? piece "")))
                  (string-split text))))

(define (regex-word-count text)
  (length (regexp-match* #px"\\b[[:alnum:]_]+\\b" text)))

(define (punctuation-sentence-count text)
  (length (regexp-match* #px"[^.!?]+[.!?]+" text)))

(define (newline-sentence-count text)
  (length (filter (lambda (line) (not (string=? (string-trim line) "")))
                  (regexp-split #px"\n+" text))))

(define (header-prefix? text header)
  (define trimmed (string-trim text))
  (or (string-prefix? trimmed header)
      (string-prefix? trimmed (string-append header ":"))))

(define (markdown-heading? text header)
  (define pattern
    (regexp (format "(?mi:^#{1,6}[[:space:]]+~a[[:space:]]*$)"
                    (regexp-quote header))))
  (and (regexp-match? pattern text) #t))

(define (string-contains-literal? text phrase)
  (and (regexp-match? (regexp (regexp-quote phrase)) text) #t))

(define (string-contains-ci? text phrase)
  (string-contains-literal? (string-downcase text) (string-downcase phrase)))

(define (string-contains-word? text phrase)
  (define pattern
    (regexp (format "(?i:(^|[^[:alnum:]_])~a([^[:alnum:]_]|$))"
                    (regexp-quote phrase))))
  (and (regexp-match? pattern text) #t))

(define (code-block? text)
  (and (regexp-match? #px"```" text) #t))

(define (param-number params keys default)
  (or (for/or ([key (in-list keys)])
        (define value (hash-ref/key params key #f))
        (and (number? value) value))
      default))

(define (param-string params keys default)
  (or (for/or ([key (in-list keys)])
        (define value (hash-ref/key params key #f))
        (and (string? value) value))
      default))

(define (hash-ref/key table key default)
  (hash-ref table
            key
            (lambda ()
              (if (symbol? key)
                  (hash-ref table (symbol->string key) default)
                  default))))

(define (->symbol/default value default)
  (cond
    [(symbol? value) value]
    [(string? value) (string->symbol value)]
    [else default]))
