#lang racket/base

(require ffi/unsafe
         racket/runtime-path)

(provide vocabulary-handle? regex-handle? state-handle?
         pcre-vocabulary-open pcre-open pcre-start pcre-step
         pcre-allowed pcre-accepted pcre-accepting? pcre-terminal?
         pcre-text-match?)

(define-runtime-path native-lib "../native/regex/build/librackllm_pcre2.so")
(define lib (ffi-lib (or (getenv "RACK_LLM_REGEX_NATIVE_LIB") native-lib)))

(define vocab-open*
  (get-ffi-obj "rackllm_vocab_open" lib
               (_fun _bytes _size _pointer _int32 _bytes _size -> _pointer)))
(define vocab-close* (get-ffi-obj "rackllm_vocab_close" lib (_fun _pointer -> _void)))
(define open*
  (get-ffi-obj "rackllm_regex_open" lib
               (_fun _string _pointer _int _bytes _size -> _pointer)))
(define close* (get-ffi-obj "rackllm_regex_close" lib (_fun _pointer -> _void)))
(define start* (get-ffi-obj "rackllm_regex_start" lib (_fun _pointer -> _pointer)))
(define state-close* (get-ffi-obj "rackllm_regex_state_close" lib (_fun _pointer -> _void)))
(define step* (get-ffi-obj "rackllm_regex_step" lib
                           (_fun _pointer _int32 _pointer -> _int)))
(define allowed-count* (get-ffi-obj "rackllm_regex_allowed_count" lib (_fun _pointer -> _int32)))
(define allowed-ref* (get-ffi-obj "rackllm_regex_allowed_ref" lib (_fun _pointer _int32 -> _int32)))
(define accepted-count* (get-ffi-obj "rackllm_regex_accepted_count" lib (_fun _pointer -> _int32)))
(define accepted-ref* (get-ffi-obj "rackllm_regex_accepted_ref" lib (_fun _pointer _int32 -> _int32)))
(define accepting* (get-ffi-obj "rackllm_regex_accepting" lib (_fun _pointer -> _int)))
(define terminal* (get-ffi-obj "rackllm_regex_terminal" lib (_fun _pointer -> _int)))
(define text-match* (get-ffi-obj "rackllm_regex_text_match" lib
                                 (_fun _string _string _bytes _size -> _int)))

(struct vocabulary-handle (ptr) #:transparent)
(struct regex-handle (ptr owner) #:transparent)
(struct state-handle (ptr owner) #:transparent)

(define (pcre-vocabulary-open token-texts)
  (define pieces
    (for/vector ([text (in-vector token-texts)])
      (string->bytes/utf-8 text)))
  (define total
    (for/sum ([piece (in-vector pieces)]) (bytes-length piece)))
  (define blob (make-bytes total))
  (define lengths (malloc _int32 (max 1 (vector-length pieces))))
  (for/fold ([offset 0]) ([piece (in-vector pieces)] [id (in-naturals)])
    (define length (bytes-length piece))
    (bytes-copy! blob offset piece)
    (ptr-set! lengths _int32 id length)
    (+ offset length))
  (define err (make-bytes 1024 0))
  (define ptr
    (vocab-open* blob total lengths (vector-length pieces) err (bytes-length err)))
  (void/reference-sink blob lengths pieces)
  (unless ptr (error 'rx "~a" (cstring err)))
  (define handle (vocabulary-handle ptr))
  (register-finalizer handle (lambda (v) (vocab-close* (vocabulary-handle-ptr v))))
  handle)

(define (pcre-open pattern vocabulary restart-safe?)
  (define err (make-bytes 1024 0))
  (define ptr
    (open* pattern
           (vocabulary-handle-ptr vocabulary)
           (if restart-safe? 1 0)
           err
           (bytes-length err)))
  (void/reference-sink vocabulary)
  (unless ptr (error 'rx "~a" (cstring err)))
  (define handle (regex-handle ptr vocabulary))
  (register-finalizer handle (lambda (v) (close* (regex-handle-ptr v))))
  handle)

(define (pcre-start regex)
  (define ptr (start* (regex-handle-ptr regex)))
  (void/reference-sink regex)
  (unless ptr (error 'rx "regex state allocation failed"))
  (wrap-state ptr regex))

(define (pcre-step state id)
  (define out (malloc _pointer 1))
  (ptr-set! out _pointer #f)
  (define status (step* (state-handle-ptr state) id out))
  (define owner (state-handle-owner state))
  (void/reference-sink state)
  (when (negative? status) (error 'rx "regex transition failed"))
  (and (positive? status) (wrap-state (ptr-ref out _pointer) owner)))

(define (pcre-allowed state)
  (define ptr (state-handle-ptr state))
  (define n (allowed-count* ptr))
  (when (negative? n) (error 'rx "allowed-token allocation failed"))
  (define ids
    (for/list ([i (in-range n)])
      (define id (allowed-ref* ptr i))
      (when (negative? id) (error 'rx "invalid allowed-token index"))
      id))
  (void/reference-sink state)
  ids)

(define (pcre-accepted state)
  (define ptr (state-handle-ptr state))
  (define n (accepted-count* ptr))
  (when (negative? n) (error 'rx "accepted-token allocation failed"))
  (define ids
    (for/list ([i (in-range n)])
      (define id (accepted-ref* ptr i))
      (when (negative? id) (error 'rx "invalid accepted-token index"))
      id))
  (void/reference-sink state)
  ids)

(define (pcre-accepting? state)
  (define result (not (zero? (accepting* (state-handle-ptr state)))))
  (void/reference-sink state)
  result)

(define (pcre-terminal? state)
  (define result (terminal* (state-handle-ptr state)))
  (void/reference-sink state)
  (when (negative? result) (error 'rx "terminal-token allocation failed"))
  (positive? result))

(define (pcre-text-match? pattern text)
  (define err (make-bytes 1024 0))
  (define rc (text-match* pattern text err (bytes-length err)))
  (when (negative? rc) (error 'rx "~a" (cstring err)))
  (positive? rc))

(define (wrap-state ptr owner)
  (define state (state-handle ptr owner))
  (register-finalizer state (lambda (v) (state-close* (state-handle-ptr v))))
  state)

(define (cstring bytes)
  (define end (or (for/first ([i (in-range (bytes-length bytes))]
                              #:when (zero? (bytes-ref bytes i))) i)
                  (bytes-length bytes)))
  (bytes->string/utf-8 (subbytes bytes 0 end) #\uFFFD))
