#lang racket/base
(require "private/program.rkt" "private/generate.rkt" "private/weak.rkt"
         "private/model.rkt" "model-llama-cpp.rkt")
(provide lit ere seq choice repeat text rule-set with-rules positive negative
         compile-spec accepts? observe observe-token-ids
         observation? observation-schema observation-labels
         observation->datum datum->observation
         fit-calibration calibration-posterior calibration-fingerprint calibration-diagnostics
         save-calibration load-calibration attach-calibration
         generation-request generate-batch
         generation-result-status generation-result-reason generation-result-token-ids
         generation-result-text generation-result-lm-logprob
         generation-result-latency-ms generation-result-tokenizer-fingerprint
         generation-result-posterior generation-result-terminal-mass
         generation-result-calibration-fingerprint generation-result-attempts
         generation-result-proposed-tokens
         generation-result-model-draws generation-result-trie-nodes
         llama-cpp-backend (rename-out [model-close! backend-close!]))
