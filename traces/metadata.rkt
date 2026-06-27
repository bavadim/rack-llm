#lang racket/base

(require racket/port
         racket/string
         racket/system)

(provide (struct-out run-metadata)
         run-metadata->json
         current-git-commit)

(struct run-metadata
  (run-id
   seed
   library-version
   git-commit
   provider-name
   provider-mode
   model-id
   model-hash
   grammar-id
   rule-set-id)
  #:transparent)

(define (run-metadata->json m)
  (hash 'run_id (run-metadata-run-id m)
        'seed (run-metadata-seed m)
        'library_version (run-metadata-library-version m)
        'git_commit (or (run-metadata-git-commit m) 'null)
        'provider_name (symbol->string (run-metadata-provider-name m))
        'provider_mode (symbol->string (run-metadata-provider-mode m))
        'model_id (run-metadata-model-id m)
        'model_hash (or (run-metadata-model-hash m) 'null)
        'grammar_id (run-metadata-grammar-id m)
        'rule_set_id (run-metadata-rule-set-id m)))

(define (current-git-commit)
  (with-handlers ([exn:fail? (lambda (_exn) #f)])
    (define git (find-executable-path "git"))
    (and git
         (parameterize ([current-error-port (open-output-string)])
           (define out
             (with-output-to-string
               (lambda ()
                 (and (system* git "rev-parse" "HEAD") (void)))))
           (define commit (string-trim out))
           (and (regexp-match? #px"^[0-9a-fA-F]{40}$" commit)
                commit)))))
