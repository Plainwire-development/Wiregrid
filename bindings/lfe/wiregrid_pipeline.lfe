;; Macro-friendly event pipelines for LFE consumers. Stages are ordinary
;; functions and execute without an intermediate process. A stage receives
;; `(event envelope)` and may return:
;;   ok | {ok, event} | drop | {error, reason}
;; ACK is emitted only for successful or intentionally dropped deliveries.
(defmodule wiregrid_pipeline
  (export all))

(defun consume (instance envelope stages)
  (case (wiregrid_fast:delivery-event instance envelope)
    ((tuple 'ok event)
      (case (run event envelope stages)
        ((tuple 'ok final-event)
          (case (wiregrid_fast:ack-delivery instance envelope)
            ((tuple 'ok _) (tuple 'ok final-event))
            (error error)))
        ('drop
          (case (wiregrid_fast:ack-delivery instance envelope)
            ((tuple 'ok _) 'drop)
            (error error)))
        (error error)))
    (error error)))

(defun run (event envelope stages)
  (run-stages event envelope stages))

(defun run-stages
  ((event _envelope ())
    (tuple 'ok event))
  ((event envelope (cons stage rest))
    (case (funcall stage event envelope)
      ('ok (run-stages event envelope rest))
      ((tuple 'ok next-event) (run-stages next-event envelope rest))
      ('drop 'drop)
      ((tuple 'error reason) (tuple 'error reason))
      (other (tuple 'error (tuple 'invalid_stage_result other))))))

;; A variant for stages that are known to preserve the event. It avoids
;; carrying replacement values through the hot loop.
(defun consume-effects (instance envelope stages)
  (case (wiregrid_fast:delivery-event instance envelope)
    ((tuple 'ok event)
      (case (run-effects event envelope stages)
        ('ok (wiregrid_fast:ack-delivery instance envelope))
        ('drop (wiregrid_fast:ack-delivery instance envelope))
        (error error)))
    (error error)))

(defun run-effects
  ((_event _envelope ()) 'ok)
  ((event envelope (cons stage rest))
    (case (funcall stage event envelope)
      ('ok (run-effects event envelope rest))
      ('drop 'drop)
      ((tuple 'error reason) (tuple 'error reason))
      (other (tuple 'error (tuple 'invalid_stage_result other))))))

;; Process a caller-selected bounded batch, defer ACKs until handling has
;; completed, then release reservations with grouped ack_many operations.
(defun consume-many (instance envelopes handler)
  (consume-many-loop instance envelopes handler () 0 0))

(defun consume-many-loop
  ((instance () _handler successful handled failed)
    (case (wiregrid_fast:ack-grouped instance (: lists reverse successful))
      ((tuple 'ok ack-result)
        (tuple 'ok #M(handled handled failed failed acks ack-result)))
      (error (tuple 'error #M(handled handled failed failed ack_error error)))))
  ((instance (cons envelope rest) handler successful handled failed)
    (case (wiregrid_fast:delivery-event instance envelope)
      ((tuple 'ok event)
        (case (funcall handler event envelope)
          ('ok
            (consume-many-loop instance rest handler (cons envelope successful)
                               (+ handled 1) failed))
          ((tuple 'ok _)
            (consume-many-loop instance rest handler (cons envelope successful)
                               (+ handled 1) failed))
          (_other
            (consume-many-loop instance rest handler successful handled (+ failed 1)))))
      (_error
        (consume-many-loop instance rest handler successful handled (+ failed 1))))))
