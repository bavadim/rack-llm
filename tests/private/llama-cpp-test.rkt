#lang racket/base

(require rackunit
         "../../model-llama-cpp.rkt")

(module+ test
  (test-case "llama-cpp provider loads native shim lazily"
    (check-exn
     #rx"cannot load native llama[.]cpp shim"
     (lambda ()
       (llama-cpp-model
        #:model-path "/missing/model.gguf"
        #:native-lib "/missing/librackllm_llama.so")))))
