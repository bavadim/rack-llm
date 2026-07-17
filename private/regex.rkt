#lang racket/base

(require ffi/unsafe racket/promise racket/runtime-path racket/string)
(provide parse-ere-pattern make-regex-vocabulary make-hard-regex make-text-regex
         regex-start regex-state-step regex-state-accepting? regex-allowed regex-text-match?)

(struct ere-pattern (source restart?) #:transparent)
(struct vocabulary (native) #:transparent)
(struct machine (native) #:transparent)
(struct state (native) #:transparent)

;; POSIX-like portable syntax translated to the PCRE2 regular subset.  Captures
;; become non-capturing groups and ^/$ always mean whole generated text.
(define (parse-ere-pattern source)
  (unless (string? source) (raise-argument-error 'ere "string?" source))
  (define n (string-length source)) (define out (open-output-string))
  (define depth 0) (define class? #f) (define first? #f)
  (define repeatable? #f) (define restart? #t)
  (let loop ([i 0])
    (cond
      [(= i n)
       (when class? (error 'ere "unterminated character class in ~s" source))
       (unless (zero? depth) (error 'ere "unterminated group in ~s" source))]
      [else
       (define ch (string-ref source i))
       (cond
         [(char=? ch #\\)
          (when (= (add1 i) n) (error 'ere "trailing escape in ~s" source))
          (define escaped (string-ref source (add1 i)))
          (unless (or (memv escaped '(#\n #\r #\t #\\ #\. #\^ #\$ #\| #\( #\)
                                      #\[ #\] #\{ #\} #\* #\+ #\? #\-))
                      (and class? (char=? escaped #\^)))
            (error 'ere "unsupported escape \\~a in ~s" escaped source))
          (write-char #\\ out) (write-char escaped out) (set! repeatable? #t) (loop (+ i 2))]
         [class?
          (cond [(and first? (char=? ch #\^)) (write-char ch out) (set! first? #f)]
                [(char=? ch #\])
                 (when first? (error 'ere "empty character class in ~s" source))
                 (write-char ch out) (set! class? #f) (set! repeatable? #t)]
                [else (write-char ch out) (set! first? #f)])
          (loop (add1 i))]
         [(char=? ch #\[)
          (write-char ch out) (set! class? #t) (set! first? #t)
          (set! repeatable? #f) (loop (add1 i))]
         [(char=? ch #\()
          (when (and (< (add1 i) n) (char=? (string-ref source (add1 i)) #\?))
            (error 'ere "PCRE extensions are unsupported in ~s" source))
          (display "(?:" out) (set! depth (add1 depth)) (set! repeatable? #f) (loop (add1 i))]
         [(char=? ch #\))
          (when (zero? depth) (error 'ere "unmatched ')' in ~s" source))
          (write-char ch out) (set! depth (sub1 depth)) (set! repeatable? #t) (loop (add1 i))]
         [(or (char=? ch #\^) (char=? ch #\$))
          (display (if (char=? ch #\^) "\\A" "\\z") out)
          (set! restart? #f) (set! repeatable? #f) (loop (add1 i))]
         [(memv ch '(#\* #\+ #\?))
          (unless repeatable? (error 'ere "quantifier has no atom in ~s" source))
          (write-char ch out) (set! repeatable? #f) (loop (add1 i))]
         [(char=? ch #\{)
          (unless repeatable? (error 'ere "quantifier has no atom in ~s" source))
          (define close (for/first ([j (in-range (add1 i) n)] #:when (char=? (string-ref source j) #\})) j))
          (unless close (error 'ere "unterminated repeat in ~s" source))
          (define body (substring source (add1 i) close))
          (define parts (string-split body "," #:trim? #f))
          (unless (and (<= 1 (length parts) 2) (regexp-match? #px"^[0-9]+$" (car parts))
                       (or (= (length parts) 1) (string=? (cadr parts) "")
                           (regexp-match? #px"^[0-9]+$" (cadr parts))))
            (error 'ere "invalid repeat {~a} in ~s" body source))
          (when (and (= (length parts) 2) (not (string=? (cadr parts) ""))
                     (> (string->number (car parts)) (string->number (cadr parts))))
            (error 'ere "repeat minimum exceeds maximum in ~s" source))
          (display (substring source i (add1 close)) out)
          (set! repeatable? #f) (loop (add1 close))]
         [(memv ch '(#\} #\])) (error 'ere "unmatched '~a' in ~s" ch source)]
         [(char=? ch #\|) (write-char ch out) (set! repeatable? #f) (loop (add1 i))]
         [else (write-char ch out) (set! repeatable? #t) (loop (add1 i))])]))
  (ere-pattern (get-output-string out) restart?))

;; Native bindings are loaded only when an ERE is compiled, not when the package
;; or the pure weak model is required.
(define-runtime-path native-lib "../native/regex/build/librackllm_pcre2.so")
(struct api (vopen vclose open close start sclose step count copy accepting match) #:transparent)
(define native
  (delay
    (define lib (ffi-lib (or (getenv "RACK_LLM_REGEX_NATIVE_LIB") native-lib)))
    (define (f name type) (get-ffi-obj name lib type))
    (define version ((f "rackllm_regex_abi_version" (_fun -> _int))))
    (unless (= version 2)
      (error 'ere "native regex ABI mismatch: expected 2, found ~a" version))
    (api (f "rackllm_vocab_open" (_fun _bytes _size _pointer _int32 _bytes _size -> _pointer))
         (f "rackllm_vocab_close" (_fun _pointer -> _void))
         (f "rackllm_regex_open" (_fun _string _pointer _int _bytes _size -> _pointer))
         (f "rackllm_regex_close" (_fun _pointer -> _void))
         (f "rackllm_regex_start" (_fun _pointer -> _pointer))
         (f "rackllm_regex_state_close" (_fun _pointer -> _void))
         (f "rackllm_regex_step" (_fun _pointer _int32 _pointer -> _int))
         (f "rackllm_regex_allowed_count" (_fun _pointer -> _int32))
         (f "rackllm_regex_allowed_copy" (_fun _pointer _pointer _int32 -> _int32))
         (f "rackllm_regex_accepting" (_fun _pointer -> _int))
         (f "rackllm_regex_match_compiled" (_fun _pointer _string -> _int)))))
(struct vh (ptr) #:transparent)
(struct mh (ptr owner) #:transparent)
(struct sh (ptr owner) #:transparent)
(define (cstring b)
  (bytes->string/utf-8 (subbytes b 0 (or (for/first ([i (in-range (bytes-length b))]
                                                     #:when (zero? (bytes-ref b i))) i)
                                        (bytes-length b))) #\uFFFD))
(define (open-vocabulary texts)
  (define a (force native))
  (define pieces (for/vector ([s (in-vector texts)]) (string->bytes/utf-8 s)))
  (define blob (apply bytes-append (vector->list pieces)))
  (define lengths (malloc _int32 (max 1 (vector-length pieces))))
  (for ([b (in-vector pieces)] [i (in-naturals)]) (ptr-set! lengths _int32 i (bytes-length b)))
  (define err (make-bytes 1024 0))
  (define ptr ((api-vopen a) blob (bytes-length blob) lengths (vector-length pieces) err 1024))
  (void/reference-sink blob lengths) (unless ptr (error 'ere "~a" (cstring err)))
  (define h (vh ptr)) (register-finalizer h (lambda (x) ((api-vclose a) (vh-ptr x)))) h)
(define (make-regex-vocabulary source)
  (vocabulary (delay (open-vocabulary (if (procedure? source) (source) source)))))
(define empty-vocabulary (make-regex-vocabulary (vector-immutable)))
(define (open-machine pattern vocab restart?)
  (define a (force native)) (define owner (force (vocabulary-native vocab)))
  (define err (make-bytes 1024 0))
  (define ptr ((api-open a) pattern (vh-ptr owner) (if restart? 1 0) err 1024))
  (unless ptr (error 'ere "~a" (cstring err)))
  (define h (mh ptr owner)) (register-finalizer h (lambda (x) ((api-close a) (mh-ptr x))))
  (machine h))
(define (make-hard-regex p vocab)
  (open-machine (format "\\A(?:~a)\\z" (ere-pattern-source p)) vocab (ere-pattern-restart? p)))
(define (make-text-regex p)
  (open-machine (format "\\A(?:[\\s\\S]*)(?:~a)[\\s\\S]*\\z" (ere-pattern-source p))
                empty-vocabulary #f))
(define (regex-start m)
  (define a (force native)) (define owner (machine-native m))
  (define ptr ((api-start a) (mh-ptr owner)))
  (unless ptr (error 'ere "regex state allocation failed"))
  (define h (sh ptr owner)) (register-finalizer h (lambda (x) ((api-sclose a) (sh-ptr x)))) (state h))
(define (regex-state-step s id)
  (define a (force native)) (define h (state-native s)) (define out (malloc _pointer 1))
  (define rc ((api-step a) (sh-ptr h) id out))
  (when (negative? rc) (error 'ere "regex transition failed"))
  (and (positive? rc)
       (let* ([owner (sh-owner h)] [next (sh (ptr-ref out _pointer) owner)])
         (register-finalizer next (lambda (x) ((api-sclose a) (sh-ptr x)))) (state next))))
(define (regex-state-accepting? s)
  (not (zero? ((api-accepting (force native)) (sh-ptr (state-native s))))))
(define (regex-allowed s)
  (define a (force native)) (define ptr (sh-ptr (state-native s)))
  (define n ((api-count a) ptr)) (when (negative? n) (error 'ere "allowed-token scan failed"))
  (define out (malloc _int32 (max 1 n) 'atomic-interior))
  (unless (= n ((api-copy a) ptr out n)) (error 'ere "allowed-token copy failed"))
  (for/vector ([i (in-range n)]) (ptr-ref out _int32 i)))
(define (regex-text-match? m text)
  (define rc ((api-match (force native)) (mh-ptr (machine-native m)) text))
  (when (negative? rc) (error 'ere "regex match failed")) (positive? rc))
