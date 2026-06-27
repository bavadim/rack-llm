#lang racket/base

(require rackunit
         rack-llm/sampling/dedupe)

(define dedupe-tests
  (test-suite
   "sampling dedupe modes"

   (test-case "string dedupe removes same final text"
     (define f (make-dedupe-filter '(string) #f))
     (check-true (f (dedupe-candidate "a" '(1) #f)))
     (check-false (f (dedupe-candidate "a" '(2) #f)))
     (check-true (f (dedupe-candidate "b" '(2) #f))))

   (test-case "token dedupe distinguishes same string with different tokens"
     (define f (make-dedupe-filter '(tokens) #f))
     (check-true (f (dedupe-candidate "a" '(1) #f)))
     (check-true (f (dedupe-candidate "a" '(2) #f)))
     (check-false (f (dedupe-candidate "x" '(1) #f))))

   (test-case "object dedupe uses caller-supplied normalized key"
     (define f
       (make-dedupe-filter
        '(object)
        (lambda (candidate)
          (and (dedupe-candidate-object candidate)
               (hash-ref (dedupe-candidate-object candidate) 'id #f)))))
     (check-true (f (dedupe-candidate "one" '(1) (hash 'id "same"))))
     (check-false (f (dedupe-candidate "two" '(2) (hash 'id "same"))))
     (check-true (f (dedupe-candidate "three" '(3) (hash 'id "other")))))

   (test-case "combined modes reject if any configured key was seen"
     (define f (make-dedupe-filter '(tokens string) #f))
     (check-true (f (dedupe-candidate "a" '(1) #f)))
     (check-false (f (dedupe-candidate "a" '(2) #f)))
     (check-false (f (dedupe-candidate "b" '(1) #f))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests dedupe-tests))
