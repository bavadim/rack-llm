#lang typed/racket/base

(require racket/promise
         racket/string)

(require/typed "pcre2-ffi.rkt"
  [#:opaque NativeRegex regex-handle?]
  [#:opaque NativeVocabulary vocabulary-handle?]
  [#:opaque NativeState state-handle?]
  [pcre-vocabulary-open (-> (Vectorof String) NativeVocabulary)]
  [pcre-open (-> String NativeVocabulary Boolean NativeRegex)]
  [pcre-start (-> NativeRegex NativeState)]
  [pcre-step (-> NativeState Natural (Option NativeState))]
  [pcre-allowed (-> NativeState (Listof Natural))]
  [pcre-accepted (-> NativeState (Listof Natural))]
  [pcre-accepting? (-> NativeState Boolean)]
  [pcre-terminal? (-> NativeState Boolean)]
  [pcre-text-match? (-> String String Boolean)])

(provide RegexProgram RegexVocabulary RegexMachine RegexState
         make-regex-vocabulary regex-vocabulary-texts
         parse-regex-program parse-regex-search-program
         instantiate-regex-machine regex-program-text-match?
         regex-initial regex-step regex-token-valid?
         regex-accepting? regex-terminal? regex-allowed-ids regex-accepted-ids)

(struct regex-program
  ([source : String] [search? : Boolean] [restart-safe? : Boolean])
  #:transparent)
(struct regex-vocabulary
  ([texts : (Vectorof String)]
   [native : (Promise NativeVocabulary)])
  #:transparent)
(struct regex-machine ([native : NativeRegex]) #:transparent)
(struct regex-state ([native : NativeState]) #:transparent)

(define-type RegexProgram regex-program)
(define-type RegexVocabulary regex-vocabulary)
(define-type RegexMachine regex-machine)
(define-type RegexState regex-state)
(define-type TokenId Natural)
(define-type TokenIds (Listof TokenId))

(: parse-regex-program (-> String RegexProgram))
(define (parse-regex-program source)
  (validate-pattern source)
  (regex-program source #f (restart-safe-source? source)))

(: parse-regex-search-program (-> String RegexProgram))
(define (parse-regex-search-program source)
  (validate-pattern source)
  (regex-program source #t (restart-safe-source? source)))

;; PCRE2's restart workspace is a streaming residual only for consuming
;; regular constructs. Anything context-sensitive is replayed from the full
;; prefix instead.
(: restart-safe-source? (-> String Boolean))
(define (restart-safe-source? source)
  (define length (string-length source))
  (let loop ([i : Natural 0]
             [in-class? : Boolean #f]
             [class-start? : Boolean #f]
             [previous : (Option Char) #f])
    (cond
      [(>= i length) (not in-class?)]
      [else
       (define ch (string-ref source i))
       (cond
         [(char=? ch #\\)
          (cond
            [(>= (add1 i) length) #f]
            [else
             (define escaped (string-ref source (add1 i)))
             (if (and (not in-class?)
                      (memv escaped '(#\b #\B #\A #\Z #\z #\G #\R #\X
                                      #\K #\C #\g #\k #\Q)))
                 #f
                 (loop (assert (+ i 2) exact-nonnegative-integer?)
                       in-class?
                       (and in-class? #f)
                       #f))])]
         [in-class?
          (cond
            [(and class-start? (char=? ch #\^))
             (loop (add1 i) #t #t previous)]
            [(and class-start? (char=? ch #\]))
             (loop (add1 i) #t #f previous)]
            [(char=? ch #\])
             (loop (add1 i) #f #f #f)]
            [else
             (loop (add1 i) #t #f previous)])]
         [(char=? ch #\[)
          (loop (add1 i) #t #t #f)]
         [(or (char=? ch #\^) (char=? ch #\$)) #f]
         [(and (char=? ch #\()
               (< (add1 i) length)
               (let ([next (string-ref source (add1 i))])
                 (or (char=? next #\*)
                     (and (char=? next #\?)
                          (or (>= (+ i 2) length)
                              (not (char=? (string-ref source (+ i 2)) #\:)))))))
          #f]
         [(and (char=? ch #\+)
               previous
               (memv previous '(#\* #\+ #\? #\})))
          #f]
         [else
          (loop (add1 i) #f #f ch)])])))

(: validate-pattern (-> String Void))
(define (validate-pattern source)
  (when (regexp-match? #px"\\\\[1-9]" source)
    (error 'rx "unsupported backreference in ~s" source))
  (when (regexp-match? #px"\\(\\?\\(" source)
    (error 'rx "unsupported capture-dependent conditional in ~s" source))
  (when (or (regexp-match? #px"\\\\[KC]" source)
            (string-contains? source "(?R)"))
    (error 'rx "unsupported PCRE2 DFA construct in ~s" source))
  (void (pcre-text-match? source "")))

(: make-regex-vocabulary (-> (Vectorof String) RegexVocabulary))
(define (make-regex-vocabulary texts)
  (regex-vocabulary texts (delay (pcre-vocabulary-open texts))))

(: native-source (-> RegexProgram String))
(define (native-source program)
  (if (regex-program-search? program)
      (format "\\A(?:[\\s\\S]*)(?:~a)[\\s\\S]*\\z" (regex-program-source program))
      (format "\\A(?:~a)\\z" (regex-program-source program))))

(: instantiate-regex-machine (-> RegexProgram RegexVocabulary RegexMachine))
(define (instantiate-regex-machine program vocabulary)
  (regex-machine
   (pcre-open (native-source program)
              (force (regex-vocabulary-native vocabulary))
              (regex-program-restart-safe? program))))

(: regex-program-text-match? (-> RegexProgram String Boolean))
(define (regex-program-text-match? program text)
  (pcre-text-match? (regex-program-source program) text))

(: regex-initial (-> RegexMachine RegexState))
(define (regex-initial machine)
  (regex-state (pcre-start (regex-machine-native machine))))

(: regex-step (-> RegexMachine RegexState TokenId (Option RegexState)))
(define (regex-step _machine state id)
  (define next (pcre-step (regex-state-native state) id))
  (and next (regex-state next)))

(: regex-token-valid? (-> RegexMachine RegexState TokenId Boolean))
(define (regex-token-valid? machine state id)
  (and (regex-step machine state id) #t))

(: regex-accepting? (-> RegexMachine RegexState Boolean))
(define (regex-accepting? _machine state)
  (pcre-accepting? (regex-state-native state)))

(: regex-terminal? (-> RegexMachine RegexState Boolean))
(define (regex-terminal? _machine state)
  (pcre-terminal? (regex-state-native state)))

(: regex-allowed-ids (-> RegexMachine RegexState TokenIds))
(define (regex-allowed-ids _machine state)
  (pcre-allowed (regex-state-native state)))

(: regex-accepted-ids (-> RegexMachine RegexState TokenIds))
(define (regex-accepted-ids _machine state)
  (pcre-accepted (regex-state-native state)))
