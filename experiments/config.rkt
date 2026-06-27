#lang racket/base

(require file/sha1
         json)

(provide (struct-out experiment-config)
         experiment-config->json
         experiment-config-hash
         write-experiment-config)

(struct experiment-config
  (provider
   model
   prompt-template
   grammar
   weak-rules
   budgets
   seed
   split-ids
   metadata)
  #:transparent)

(define (experiment-config->json cfg)
  (hash 'provider (symbol->string (experiment-config-provider cfg))
        'model (experiment-config-model cfg)
        'prompt_template (experiment-config-prompt-template cfg)
        'grammar (experiment-config-grammar cfg)
        'weak_rules (experiment-config-weak-rules cfg)
        'budgets (experiment-config-budgets cfg)
        'seed (experiment-config-seed cfg)
        'split_ids (experiment-config-split-ids cfg)
        'metadata (experiment-config-metadata cfg)
        'config_hash (experiment-config-hash cfg)))

(define (experiment-config-hash cfg)
  (sha1 (open-input-string (format "~s" (canonicalize (experiment-config->hash cfg))))))

(define (write-experiment-config cfg path)
  (call-with-output-file path
    (lambda (out)
      (write-json (json-key-safe (experiment-config->json cfg)) out)
      (newline out))
    #:exists 'replace))

(define (experiment-config->hash cfg)
  (hash 'provider (experiment-config-provider cfg)
        'model (experiment-config-model cfg)
        'prompt-template (experiment-config-prompt-template cfg)
        'grammar (experiment-config-grammar cfg)
        'weak-rules (experiment-config-weak-rules cfg)
        'budgets (experiment-config-budgets cfg)
        'seed (experiment-config-seed cfg)
        'split-ids (experiment-config-split-ids cfg)
        'metadata (experiment-config-metadata cfg)))

(define (canonicalize value)
  (cond
    [(hash? value)
     (map (lambda (key)
            (cons key (canonicalize (hash-ref value key))))
          (sort (hash-keys value) canonical-key<?))]
    [(list? value) (map canonicalize value)]
    [else value]))

(define (canonical-key<? left right)
  (string<? (format "~s" left) (format "~s" right)))

(define (json-key-safe value)
  (cond
    [(hash? value)
     (for/hash ([(key nested-value) (in-hash value)])
       (values (json-key-safe-key key) (json-key-safe nested-value)))]
    [(list? value) (map json-key-safe value)]
    [else value]))

(define (json-key-safe-key key)
  (cond
    [(symbol? key) key]
    [(string? key) (string->symbol key)]
    [else key]))
