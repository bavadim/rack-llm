#lang racket/base

(require racket/list
         racket/match
         racket/path
         racket/port
         racket/string)

(define repo-root (current-directory))

(define core-roots '("main.rkt" "model-qwen.rkt"))
(define deny-exports
  '(neg-inf
    log-score-add
    log-score-dead?
    log-score>?
    FilterState
    filter-initial
    filter-step
    filter-allowed-ids
    filter-accepting?
    filter-terminal?
    filter-dead?
    filter-score
    filter-accepted-score
    filter-potential
    filter-value
    filter-token-ids
    filter-trace
    make-lit-filter
    make-rx-filter
    make-pure-filter
    make-choice-filter
    make-seq-filter
    make-repeat-filter
    make-bind-filter
    make-score-filter
    make-text-filter
    make-rank-watcher
    make-ban-watcher
    make-weighted-rule
    make-weighted-watcher
    select-token
    candidate-ids
    top-k-ids
    make-rng
    gumbel
    token-selection
    token-selection-id
    token-selection-lm-logprob
    token-selection-dead-count
    token-selection-next-state
    token-selection-candidate-count
    rx-machine
    compile-regex-machine))

(define size-budgets
  (hash "main.rkt" 650
        "model-qwen.rkt" 300
        "private/filter.rkt" 750
        "private/logits.rkt" 100
        "private/model.rkt" 250
        "private/regex.rkt" 550
        "private/sampling.rkt" 250
        "tests/contract-test.rkt" 300
        "tests/e2e-real-test.rkt" 350
        "tests/e2e-sampler-test.rkt" 300))

(define (existing-rkt-files dir)
  (if (directory-exists? dir)
      (sort
       (for/list ([entry (in-list (directory-list dir))]
                  #:when (regexp-match? #rx"[.]rkt$" (path->string entry)))
         (path->string (build-path dir entry)))
       string<?)
      '()))

(define (repo-relative path)
  (path->string
   (find-relative-path repo-root
                       (simplify-path (path->complete-path path repo-root)))))

(define (existing-rkt-files/recursive dir)
  (if (directory-exists? dir)
      (sort
       (for/list ([path (in-directory dir)]
                  #:when (regexp-match? #rx"[.]rkt$" (path->string path)))
         (repo-relative path))
       string<?)
      '()))

(define core-files
  (filter file-exists?
          (append core-roots
                  (existing-rkt-files "private")
                  (existing-rkt-files/recursive "tests"))))

(define core-file-set (for/hash ([file (in-list core-files)]) (values file #t)))

(define (module-base file)
  (let ([dir (path-only (path->complete-path file repo-root))])
    (or dir repo-root)))

(define (local-path? s)
  (and (string? s)
       (regexp-match? #rx"[.]rkt$" s)))

(define (resolve-local from-file s)
  (and (local-path? s)
       (repo-relative (build-path (module-base from-file) s))))

(define (read-source-forms file)
  (call-with-input-file file
    (lambda (in)
      (read-line in 'any)
      (let loop ([forms '()])
        (define next (read in))
        (if (eof-object? next)
            (reverse forms)
            (loop (cons next forms)))))))

(define (top-level-forms file)
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (error 'arch-lint "cannot read ~a: ~a" file (exn-message exn)))])
    (read-source-forms file)))

(define (require-specs forms)
  (append*
   (for/list ([form (in-list forms)]
              #:when (and (pair? form) (eq? (car form) 'require)))
     (cdr form))))

(define (provide-specs forms)
  (append*
   (for/list ([form (in-list forms)]
              #:when (and (pair? form) (eq? (car form) 'provide)))
     (cdr form))))

(define (spec-local-deps from-file spec)
  (cond
    [(string? spec)
     (define resolved (resolve-local from-file spec))
     (if resolved (list resolved) '())]
    [(and (pair? spec) (eq? (car spec) 'submod))
     (match spec
       [(list 'submod (? string? p) _ ...)
        (define resolved (resolve-local from-file p))
        (if resolved (list resolved) '())]
       [_ '()])]
    [(pair? spec)
     (define head (car spec))
     (cond
       [(memq head '(only-in except-in rename-in prefix-in combine-in for-syntax for-template
                             for-label for-meta only-meta-in))
        (append* (map (lambda (part) (spec-local-deps from-file part)) (cdr spec)))]
       [else '()])]
    [else '()]))

(define (broad-local-require? spec)
  (or (string? spec)
      (and (pair? spec)
           (eq? (car spec) 'submod)
           (match spec
             [(list 'submod (? string?) _ ...) #t]
             [_ #f]))))

(define (provide-ids spec)
  (cond
    [(symbol? spec) (list spec)]
    [(pair? spec)
     (match spec
       [(list 'rename-out rename-specs ...)
        (for/list ([rename-spec (in-list rename-specs)]
                   #:when (and (list? rename-spec)
                               (= (length rename-spec) 2)
                               (symbol? (cadr rename-spec))))
          (cadr rename-spec))]
       [(list 'all-defined-out) '(all-defined-out)]
       [(list 'all-from-out _ ...) '(all-from-out)]
       [_ '()])]
    [else '()]))

(struct module-info
  (file lines require-count provide-count deps broad-local-requires provided)
  #:transparent)

(define (line-count file)
  (call-with-input-file file
    (lambda (in)
      (for/sum ([line (in-lines in)]) 1))))

(define (analyze-file file)
  (define forms (top-level-forms file))
  (define reqs (require-specs forms))
  (define provs (provide-specs forms))
  (define deps
    (remove-duplicates
     (filter (lambda (dep) (hash-has-key? core-file-set dep))
             (append* (map (lambda (spec) (spec-local-deps file spec)) reqs)))
     string=?))
  (define broad
    (remove-duplicates
     (filter (lambda (dep) (hash-has-key? core-file-set dep))
             (append*
              (for/list ([spec (in-list reqs)]
                         #:when (broad-local-require? spec))
                (spec-local-deps file spec))))
     string=?))
  (module-info file
               (line-count file)
               (length reqs)
               (length provs)
               deps
               broad
               (remove-duplicates (append* (map provide-ids provs)) eq?)))

(define infos (map analyze-file core-files))
(define info-by-file (for/hash ([info (in-list infos)]) (values (module-info-file info) info)))

(define (private-file? file) (string-prefix? file "private/"))
(define (test-file? file) (string-prefix? file "tests/"))
(define (private-test-file? file) (string-prefix? file "tests/private/"))

(define (edge-violations info)
  (define from (module-info-file info))
  (for/list ([to (in-list (module-info-deps info))]
             #:when
             (cond
               [(and (private-file? from) (not (private-file? to))) #t]
               [(and (string=? from "private/regex.rkt") (private-file? to)) #t]
               [(and (string=? from "private/filter.rkt")
                     (private-file? to)
                     (not (string=? to "private/regex.rkt"))) #t]
               [(and (string=? from "private/model.rkt")
                     (private-file? to)
                     (not (string=? to "private/logits.rkt"))) #t]
               [(and (string=? from "private/sampling.rkt")
                     (not (member to '("private/filter.rkt" "private/logits.rkt")))) #t]
               [(and (string=? from "model-qwen.rkt")
                     (private-file? to)
                     (not (member to '("private/model.rkt" "private/logits.rkt")))) #t]
               [(and (test-file? from) (private-file? to) (not (private-test-file? from))) #t]
               [else #f]))
    (format "~a must not require ~a" from to)))

(define (cycle-violations)
  (define visiting (make-hash))
  (define visited (make-hash))
  (define cycles '())
  (define (visit node stack)
    (cond
      [(hash-ref visiting node #f)
       (define cycle (reverse (cons node (takef stack (lambda (x) (not (string=? x node)))))))
       (set! cycles (cons (string-join cycle " -> ") cycles))]
      [(not (hash-ref visited node #f))
       (hash-set! visiting node #t)
       (for ([dep (in-list (module-info-deps (hash-ref info-by-file node)))])
         (visit dep (cons node stack)))
       (hash-remove! visiting node)
       (hash-set! visited node #t)]))
  (for ([file (in-list core-files)]) (visit file '()))
  (remove-duplicates cycles string=?))

(define (export-violations)
  (define main-info (hash-ref info-by-file "main.rkt" #f))
  (if main-info
      (append
       (for/list ([name (in-list '(all-defined-out all-from-out))]
                  #:when (memq name (module-info-provided main-info)))
         (format "main.rkt must not use broad provide form ~a" name))
       (for/list ([name (in-list deny-exports)]
                  #:when (memq name (module-info-provided main-info)))
         (format "main.rkt must not export internal identifier ~a" name)))
      '()))

(define (print-report)
  (printf "Architecture report\n")
  (printf "===================\n")
  (printf "Core modules: ~a\n\n" (length core-files))
  (printf "Module size and surface\n")
  (for ([info (in-list infos)])
    (define file (module-info-file info))
    (define budget (hash-ref size-budgets file #f))
    (define size-note
      (cond
        [(and budget (> (module-info-lines info) budget))
         (format " WARN budget ~a" budget)]
        [budget (format " budget ~a" budget)]
        [else ""]))
    (printf "  ~a: ~a lines, ~a require specs, ~a provide specs~a\n"
            file
            (module-info-lines info)
            (module-info-require-count info)
            (module-info-provide-count info)
            size-note))
  (printf "\nLocal dependency graph\n")
  (for ([info (in-list infos)])
    (printf "  ~a -> ~a\n"
            (module-info-file info)
            (if (null? (module-info-deps info))
                "[]"
                (string-join (module-info-deps info) ", "))))
  (printf "\nFan in/out\n")
  (for ([info (in-list infos)])
    (define file (module-info-file info))
    (define fan-out (length (module-info-deps info)))
    (define fan-in
      (for/sum ([other (in-list infos)])
        (if (member file (module-info-deps other)) 1 0)))
    (printf "  ~a: fan-in ~a, fan-out ~a\n" file fan-in fan-out))
  (define broad-warnings
    (append*
     (for/list ([info (in-list infos)])
       (for/list ([dep (in-list (module-info-broad-local-requires info))])
         (format "~a broadly requires ~a; consider only-in"
                 (module-info-file info)
                 dep)))))
  (unless (null? broad-warnings)
    (printf "\nWide local require warnings\n")
    (for ([warning (in-list broad-warnings)])
      (printf "  WARN ~a\n" warning))))

(define check-requires-files
  (filter (lambda (file) (not (test-file? file))) core-files))

(define (ignored-check-requires-line? line)
  (or (not (string-prefix? line "DROP "))
      (regexp-match? #rx"typed-racket/utils/redirect-contract" line)
      (regexp-match? #rx"#%contract-defs-reference" line)))

(define (run-check-requires)
  (define raco-name (or (getenv "RACO") "raco"))
  (define raco (or (find-executable-path raco-name) raco-name))
  (define-values (proc out in err)
    (apply subprocess #f #f #f raco "check-requires" check-requires-files))
  (close-output-port in)
  (define stdout (port->string out))
  (define stderr (port->string err))
  (subprocess-wait proc)
  (define status (subprocess-status proc))
  (define-values (_current actionable-reversed)
    (for/fold ([current-file #f]
               [actionable '()])
              ([line (in-list (string-split stdout "\n"))])
      (match (regexp-match #rx"^\\(file \"([^\"]+)\"\\):" line)
        [(list _ file) (values file actionable)]
        [_ (if (and (string-prefix? line "DROP ")
                    (not (ignored-check-requires-line? line)))
               (values current-file
                       (cons (format "~a: ~a" (or current-file "<unknown>") line)
                             actionable))
               (values current-file actionable))])))
  (define actionable (reverse actionable-reversed))
  (printf "\ncheck-requires\n")
  (cond
    [(not (zero? status))
     (printf "~a~a" stdout stderr)
     (list (format "raco check-requires exited with status ~a" status))]
    [(null? actionable)
     (printf "  no actionable drops\n")
     '()]
    [else
     (for ([line (in-list actionable)])
       (printf "  ~a\n" line))
     (map (lambda (line) (format "unused require: ~a" line)) actionable)]))

(define (main)
  (print-report)
  (define violations
    (append (append* (map edge-violations infos))
            (map (lambda (cycle) (format "local dependency cycle: ~a" cycle))
                 (cycle-violations))
            (export-violations)
            (run-check-requires)))
  (if (null? violations)
      (begin
        (printf "\narch-lint: ok\n")
        (void))
      (begin
        (printf "\narch-lint: failed\n")
        (for ([violation (in-list violations)])
          (printf "  ERROR ~a\n" violation))
        (exit 1))))

(module+ main
  (main))
