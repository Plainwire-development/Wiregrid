;; Stateful bounded delivery folds for LFE applications.
;;
;; The canonical Wiregrid runtime owns delivery reservation/backpressure. This
;; helper only operates on an already-bounded list of envelopes supplied by the
;; application. Each envelope is decoded at most once. A reducer receives
;; (Event, Envelope, Accumulator) and returns one of:
;;
;;   {ok, NewAccumulator}  - commit this item and ACK it at the end
;;   drop                  - intentionally consume/ACK without changing state
;;   {drop, NewAccumulator}- intentionally consume/ACK and update state
;;   anything else         - stop immediately; failed and remaining deliveries
;;                           stay unacknowledged/reserved
;;
;; Successful-prefix ACKs are grouped per session, which avoids one runtime call
;; per delivery while preserving Wiregrid's "ACK after application work" rule.
(defmodule wiregrid_fold
  (export all))

(defun consume (instance envelopes accumulator reducer)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (valid-options envelopes reducer)
        ('ok (fold-loop instance envelopes accumulator reducer () 0))
        (error error)))
    (error error)))

(defun fold-loop
  ((instance () accumulator _reducer successful handled)
    (finish instance accumulator successful handled 0 'undefined))
  ((instance (cons envelope rest) accumulator reducer successful handled)
    (case (wiregrid_fast:delivery-event instance envelope)
      ((tuple 'ok event)
        (case (funcall reducer event envelope accumulator)
          ((tuple 'ok next)
            (fold-loop instance rest next reducer (cons envelope successful) (+ handled 1)))
          ('drop
            (fold-loop instance rest accumulator reducer (cons envelope successful) (+ handled 1)))
          ((tuple 'drop next)
            (fold-loop instance rest next reducer (cons envelope successful) (+ handled 1)))
          (failure
            (finish instance accumulator successful handled
                    (+ 1 (: erlang length rest)) failure))))
      (failure
        (finish instance accumulator successful handled
                (+ 1 (: erlang length rest)) failure)))))

(defun finish (instance accumulator successful handled remaining failure)
  (case successful
    (() (result accumulator handled remaining failure #M(acked 0 unknown 0)))
    (_
      (case (wiregrid_fast:ack-grouped instance (: lists reverse successful))
        ((tuple 'ok ack-result)
          (result accumulator handled remaining failure ack-result))
        (ack-error
          (tuple 'error #M(value accumulator
                            handled handled
                            remaining remaining
                            failure failure
                            ack_error ack-error)))))))

(defun result
  ((accumulator handled 0 'undefined ack-result)
    (tuple 'ok #M(value accumulator handled handled remaining 0 acks ack-result)))
  ((accumulator handled remaining failure ack-result)
    (tuple 'error #M(value accumulator
                      handled handled
                      remaining remaining
                      failure failure
                      acks ack-result))))

(defun valid-options (envelopes reducer)
  (cond
    ((not (is_list envelopes)) (tuple 'error 'invalid_envelopes))
    ((not (is_function reducer 3)) (tuple 'error 'invalid_reducer))
    ('true 'ok)))
