;; Decode-once, grouped-ACK selectors for high-throughput LFE consumers.
;;
;; These helpers intentionally operate on already delivered Wiregrid envelopes.
;; They never bypass the canonical runtime: ACK ownership, payload decoding and
;; delivery reservation release still go through wiregrid_api/wiregrid_fast.
(defmodule wiregrid_selector
  (export all))

(defun consume-routed (instance envelopes routes default-handler)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (wiregrid_router:valid-routes routes default-handler)
        ('ok
          (consume-loop instance envelopes
            (lambda (event envelope)
              (wiregrid_router:handle-event event envelope routes default-handler))))
        (error error)))
    (error error)))

(defun consume-classified (instance envelopes durable-handler ephemeral-handler)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (valid-handler-pair durable-handler ephemeral-handler)
        ('ok
          (consume-loop instance envelopes
            (lambda (event envelope)
              (case (: maps get 'class envelope 'undefined)
                ('durable (funcall durable-handler event envelope))
                ('ephemeral (funcall ephemeral-handler event envelope))
                (other (tuple 'error (tuple 'invalid_delivery_class other)))))))
        (error error)))
    (error error)))

;; Request/reply correlation is carried in envelope.context. A normal delivery
;; can be handled by default-handler or rejected when it is `undefined`.
(defun consume-correlated (instance envelopes request-handler reply-handler default-handler)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (valid-correlation-handlers request-handler reply-handler default-handler)
        ('ok
          (consume-loop instance envelopes
            (lambda (event envelope)
              (let ((context (: maps get 'context envelope #M())))
                (case (context-kind context)
                  ('request (funcall request-handler event envelope))
                  ('reply (funcall reply-handler event envelope))
                  (_ (dispatch-default default-handler event envelope)))))))
        (error error)))
    (error error)))

(defun consume-loop (instance envelopes handler)
  (consume-loop instance envelopes handler () 0 0))

(defun consume-loop
  ((instance () _handler successful handled failed)
    (case successful
      (() (tuple 'ok #M(handled handled failed failed acks #M(acked 0 unknown 0))))
      (_
        (case (wiregrid_fast:ack-grouped instance (: lists reverse successful))
          ((tuple 'ok ack-result)
            (tuple 'ok #M(handled handled failed failed acks ack-result)))
          (error
            (tuple 'error #M(handled handled failed failed ack_error error)))))))
  ((instance (cons envelope rest) handler successful handled failed)
    (case (wiregrid_fast:delivery-event instance envelope)
      ((tuple 'ok event)
        (case (funcall handler event envelope)
          ('ok
            (consume-loop instance rest handler (cons envelope successful)
                          (+ handled 1) failed))
          ((tuple 'ok _value)
            (consume-loop instance rest handler (cons envelope successful)
                          (+ handled 1) failed))
          ('drop
            (consume-loop instance rest handler (cons envelope successful)
                          (+ handled 1) failed))
          (_other
            ;; A failed item intentionally remains unacknowledged so Wiregrid's
            ;; reservation/backpressure model continues to reflect unfinished work.
            (consume-loop instance rest handler successful handled (+ failed 1)))))
      (_error
        (consume-loop instance rest handler successful handled (+ failed 1))))))


(defun context-kind (context)
  (case (is_map context)
    ('true (: maps get 'kind context 'undefined))
    ('false 'undefined)))

(defun dispatch-default
  (('undefined _event _envelope) (tuple 'error 'no_default_handler))
  ((handler event envelope) (funcall handler event envelope)))

(defun valid-handler-pair (durable-handler ephemeral-handler)
  (cond
    ((not (is_function durable-handler 2)) (tuple 'error 'invalid_durable_handler))
    ((not (is_function ephemeral-handler 2)) (tuple 'error 'invalid_ephemeral_handler))
    ('true 'ok)))

(defun valid-correlation-handlers (request-handler reply-handler default-handler)
  (cond
    ((not (is_function request-handler 2)) (tuple 'error 'invalid_request_handler))
    ((not (is_function reply-handler 2)) (tuple 'error 'invalid_reply_handler))
    ((andalso (/= default-handler 'undefined)
              (not (is_function default-handler 2)))
      (tuple 'error 'invalid_default_handler))
    ('true 'ok)))
