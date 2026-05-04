#lang racket

(require rack-llm
         rack-llm/backends/openai-compatible)

(define model
  (make-openai-compatible-model
   #:model (or (getenv "OPENAI_MODEL") "gpt-4.1-mini")
   #:base-url (or (getenv "OPENAI_BASE_URL") "https://api.openai.com/v1")))

(define-grammar (label-g ctx)
  (gen #:as 'label
       #:regex #px"[^\n]{1,32}"
       #:max-tokens 12
       #:temperature 0.8))

(define bad-endings
  (set "и" "или" "но" "а" "что" "чтобы" "для" "с" "в" "на" "по" "к"))

(define (no-dangling-ending ctx cand)
  (define words
    (string-split
     (string-downcase
      (string-trim (candidate-text cand) " .,!?;:"))))
  (cond
    [(null? words)
     (fail "empty label" #:hint "Сгенерируй непустую законченную фразу.")]
    [(set-member? bad-endings (last words))
     (fail "label ends with a dangling function word"
           #:hint "Не заканчивай фразу союзом или предлогом.")]
    [else
     (pass #:score 0.7)]))

(define (keeps-placeholders ctx cand)
  (define required (hash-ref ctx 'placeholders '()))
  (define missing
    (filter-not
     (lambda (p) (string-contains? (candidate-text cand) p))
     required))
  (if (null? missing)
      (pass #:score 1.0)
      (fail "missing placeholders"
            #:hint (format "Сохрани placeholders дословно: ~a" missing))))

(define ctx
  (hash 'placeholders '("{count}")))

(define res
  (run model
       (chat
        (system "Ты пишешь короткие UI labels на русском.")
        (user "Кнопка удаляет {count} выбранных файлов.")
        (assistant
         (best-of (label-g ctx)
                  #:as 'label
                  #:tries 8
                  #:context ctx
                  #:reviewers
                  (list
                   (weighted 2 no-dangling-ending)
                   (weighted 10 keeps-placeholders))
                  #:weigh weighted-score)))))

(displayln (result-ref res 'label))
