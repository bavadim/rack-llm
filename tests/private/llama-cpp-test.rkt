#lang racket/base

(require rackunit
         "../../model-llama-cpp.rkt")

(module+ test
  (test-case "llama-cpp provider loads native shim lazily"
    (check-exn
     #rx"cannot load native llama[.]cpp shim"
     (lambda ()
       (llama-cpp-backend
        #:model-path "/missing/model.gguf"
        #:cohort-width 4
        #:context-per-lane 128
        #:native-lib "/missing/librackllm_llama.so")))))
