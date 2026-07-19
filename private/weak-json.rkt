#lang racket/base

(require json racket/file racket/path)

(provide read-json-file write-json-file)

(define (read-json-file path)
  (call-with-input-file path read-json))

(define (write-json-file value path)
  (define target (path->complete-path path))
  (define temporary
    (make-temporary-file "calibration-~a.json" #f
                         (or (path-only target) (current-directory))))
  (with-handlers ([exn:fail? (lambda (exn)
                               (when (file-exists? temporary) (delete-file temporary))
                               (raise exn))])
    (call-with-output-file temporary
      (lambda (out) (write-json value out) (newline out))
      #:exists 'truncate/replace)
    (rename-file-or-directory temporary target #t)))
