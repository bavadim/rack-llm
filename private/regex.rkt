#lang typed/racket/base

(require racket/list
         racket/promise
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

(provide RegexProgram ErePattern RegexVocabulary RegexMachine RegexState
         make-regex-vocabulary regex-vocabulary-texts
         parse-regex-program parse-regex-search-program
         parse-ere-pattern ere-pattern-source ere-pattern-has-end-anchor?
         ere-full-program ere-search-program literal-search-program
         instantiate-regex-machine regex-program-text-match?
         regex-initial regex-step regex-token-valid?
         regex-accepting? regex-terminal? regex-allowed-ids regex-accepted-ids)

(struct regex-program
  ([source : String] [search? : Boolean] [restart-safe? : Boolean])
  #:transparent)
(struct ere-pattern
  ([source : String] [compiled : String] [has-end-anchor? : Boolean])
  #:transparent)
(struct regex-vocabulary
  ([texts : (Vectorof String)]
   [native : (Promise NativeVocabulary)])
  #:transparent)
(struct regex-machine ([native : NativeRegex]) #:transparent)
(struct regex-state ([native : NativeState]) #:transparent)

(define-type RegexProgram regex-program)
(define-type ErePattern ere-pattern)
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

;; `ere` is deliberately a small, reproducible language. PCRE2 remains the
;; execution engine, but user input is parsed through this allowlist first.
(: parse-ere-pattern (-> String ErePattern))
(define (parse-ere-pattern source)
  (define source-length (string-length source))
  (define out (open-output-string))
  (define has-end? : Boolean #f)
  (define group-depth : Natural 0)
  (define in-class? : Boolean #f)
  (define class-first? : Boolean #f)
  (define can-repeat? : Boolean #f)
  (let loop : Void ([i : Natural 0])
    (cond
      [(>= i source-length)
       (when in-class? (error 'ere "unterminated character class in ~s" source))
       (unless (zero? group-depth) (error 'ere "unterminated group in ~s" source))
       (void)]
      [else
       (define ch (string-ref source i))
       (cond
         [(char=? ch #\\)
          (when (>= (add1 i) source-length) (error 'ere "trailing escape in ~s" source))
          (define escaped (string-ref source (add1 i)))
          (unless (or (memv escaped '(#\n #\r #\t #\\ #\. #\^ #\$ #\| #\(
                                      #\) #\[ #\] #\{ #\} #\* #\+ #\? #\-))
                      (and in-class? (char=? escaped #\^)))
            (error 'ere "unsupported escape \\~a in ~s" escaped source))
          (write-char #\\ out)
          (write-char escaped out)
          (set! can-repeat? #t)
          (loop (assert (+ i 2) exact-nonnegative-integer?))]
         [in-class?
          (cond
            [(and class-first? (char=? ch #\^))
             (write-char ch out)
             (set! class-first? #f)
             (loop (add1 i))]
            [(char=? ch #\])
             (when class-first? (error 'ere "empty character class in ~s" source))
             (write-char ch out)
             (set! in-class? #f)
             (set! can-repeat? #t)
             (loop (add1 i))]
            [else
             (write-char ch out)
             (set! class-first? #f)
             (loop (add1 i))])]
         [(char=? ch #\[)
          (write-char ch out)
          (set! in-class? #t)
          (set! class-first? #t)
          (set! can-repeat? #f)
          (loop (add1 i))]
         [(char=? ch #\()
          (when (and (< (add1 i) source-length) (char=? (string-ref source (add1 i)) #\?))
            (error 'ere "PCRE extensions are unsupported in ~s" source))
          (display "(?:" out)
          (set! group-depth (add1 group-depth))
          (set! can-repeat? #f)
          (loop (add1 i))]
         [(char=? ch #\))
          (when (zero? group-depth) (error 'ere "unmatched ')' in ~s" source))
          (write-char ch out)
          (set! group-depth (assert (sub1 group-depth) exact-nonnegative-integer?))
          (set! can-repeat? #t)
          (loop (add1 i))]
         [(char=? ch #\^)
          (display "\\A" out)
          (set! can-repeat? #f)
          (loop (add1 i))]
         [(char=? ch #\$)
          (display "\\z" out)
          (set! has-end? #t)
          (set! can-repeat? #f)
          (loop (add1 i))]
         [(or (char=? ch #\*) (char=? ch #\+) (char=? ch #\?))
          (unless can-repeat? (error 'ere "quantifier has no atom in ~s" source))
          (write-char ch out)
          (set! can-repeat? #f)
          (loop (add1 i))]
         [(char=? ch #\{)
          (unless can-repeat? (error 'ere "quantifier has no atom in ~s" source))
          (define close : (Option Natural)
            (let find : (Option Natural) ([j : Natural (add1 i)])
              (cond [(>= j source-length) #f]
                    [(char=? (string-ref source j) #\}) j]
                    [else (find (add1 j))])))
          (unless close (error 'ere "unterminated repeat in ~s" source))
          (define close* (assert close exact-nonnegative-integer?))
          (define body (substring source (add1 i) close*))
          (define parts (string-split body "," #:trim? #f))
          (unless (and (or (= (length parts) 1) (= (length parts) 2))
                       (regexp-match? #px"^[0-9]+$" (car parts))
                       (or (= (length parts) 1)
                           (string=? (cadr parts) "")
                           (regexp-match? #px"^[0-9]+$" (cadr parts))))
            (error 'ere "invalid repeat {~a} in ~s" body source))
          (when (and (= (length parts) 2) (not (string=? (cadr parts) ""))
                     (> (assert (string->number (car parts)) exact-nonnegative-integer?)
                        (assert (string->number (cadr parts)) exact-nonnegative-integer?)))
            (error 'ere "repeat minimum exceeds maximum in ~s" source))
          (display (substring source i (add1 close*)) out)
          (set! can-repeat? #f)
          (loop (add1 close*))]
         [(or (char=? ch #\}) (char=? ch #\]))
          (error 'ere "unmatched '~a' in ~s" ch source)]
         [(char=? ch #\|)
          (write-char ch out)
          (set! can-repeat? #f)
          (loop (add1 i))]
         [else
          (write-char ch out)
          (set! can-repeat? #t)
          (loop (add1 i))])]))
  (define compiled (get-output-string out))
  (validate-pattern compiled)
  (ere-pattern source compiled has-end?))

(: ere-full-program (-> ErePattern RegexProgram))
(define (ere-full-program pattern)
  (define source (ere-pattern-compiled pattern))
  (regex-program source #f (restart-safe-source? source)))

(: ere-search-program (-> ErePattern RegexProgram))
(define (ere-search-program pattern)
  (define source (ere-pattern-compiled pattern))
  (regex-program source #t (restart-safe-source? source)))

(: quote-literal (-> String String))
(define (quote-literal source)
  (list->string
   (append-map
    (lambda ([ch : Char])
      (if (memv ch '(#\\ #\. #\^ #\$ #\| #\( #\) #\[ #\] #\{ #\} #\* #\+ #\?))
          (list #\\ ch)
          (list ch)))
    (string->list source))))

(: literal-search-program (-> String RegexProgram))
(define (literal-search-program source)
  (define quoted (quote-literal source))
  (regex-program quoted #t (restart-safe-source? quoted)))

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
