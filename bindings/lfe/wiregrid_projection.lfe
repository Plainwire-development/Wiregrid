;; Macro-friendly commit-before-ACK projections for LFE applications.
;;
;; The state/ACK semantics live in Wiregrid.Consumer and are exposed through
;; wiregrid_api so Elixir, Erlang, Gleam and LFE all share one implementation.
;; LFE keeps the compile-time specialization layer without forking correctness.
(defmodule wiregrid_projection
  (export all))

(defun consume (instance envelopes accumulator reducer commit)
  (wiregrid_api:consume_projection instance envelopes accumulator reducer commit))
