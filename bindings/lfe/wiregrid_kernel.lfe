;; Decode-late batch kernel for macro-specialized LFE consumers.
;;
;; A selector examines the delivery envelope before payload decoding and returns
;; one of:
;;   ack                    -- consume/ACK without decoding
;;   keep                   -- deliberately retain the reservation
;;   {handle, Handler/2}    -- decode once, then invoke Handler(Event, Envelope)
;;   {error, Reason}        -- reject this item and retain the reservation
;;
;; This is useful for fixed topic/class/correlation programs where many
;; deliveries can be classified from envelope metadata alone. ACK ownership and
;; payload decoding remain canonical Wiregrid operations through wiregrid_api.
(defmodule wiregrid_kernel
  (export all))

(defun consume (instance envelopes selector)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (is_function selector 1)
        ('true (consume-loop instance envelopes selector () 0 0 0 0))
        ('false (tuple 'error 'invalid_selector))))
    (error error)))

(defun consume-loop
  ((instance () _selector successful handled ack-only kept failed)
    (finish instance successful handled ack-only kept failed))
  ((instance (cons envelope rest) selector successful handled ack-only kept failed)
    (case (safe-select selector envelope)
      ('ack
        (consume-loop instance rest selector (cons envelope successful)
                      handled (+ ack-only 1) kept failed))
      ('keep
        (consume-loop instance rest selector successful handled ack-only (+ kept 1) failed))
      ((tuple 'handle handler)
        (case (is_function handler 2)
          ('true
            (case (wiregrid_fast:delivery-event instance envelope)
              ((tuple 'ok event)
                (case (safe-handle handler event envelope)
                  ('ok
                    (consume-loop instance rest selector (cons envelope successful)
                                  (+ handled 1) ack-only kept failed))
                  ('drop
                    (consume-loop instance rest selector (cons envelope successful)
                                  (+ handled 1) ack-only kept failed))
                  ((tuple 'ok _value)
                    (consume-loop instance rest selector (cons envelope successful)
                                  (+ handled 1) ack-only kept failed))
                  (_
                    (consume-loop instance rest selector successful
                                  handled ack-only kept (+ failed 1)))))
              (_
                (consume-loop instance rest selector successful
                              handled ack-only kept (+ failed 1)))))
          ('false
            (consume-loop instance rest selector successful
                          handled ack-only kept (+ failed 1)))))
      ((tuple 'error _reason)
        (consume-loop instance rest selector successful
                      handled ack-only kept (+ failed 1)))
      (_other
        (consume-loop instance rest selector successful
                      handled ack-only kept (+ failed 1))))))

(defun finish
  ((_instance () handled ack-only kept failed)
    (tuple 'ok #M(handled handled ack_only ack-only kept kept failed failed
                  acks #M(acked 0 unknown 0))))
  ((instance successful handled ack-only kept failed)
    (case (wiregrid_fast:ack-grouped instance (: lists reverse successful))
      ((tuple 'ok ack-result)
        (tuple 'ok #M(handled handled ack_only ack-only kept kept failed failed
                      acks ack-result)))
      (error
        (tuple 'error #M(handled handled ack_only ack-only kept kept failed failed
                        ack_error error))))))



;; Ordered consumption is for stateful streams where processing after the first
;; failed delivery would violate application ordering. Successful prefix items
;; are ACKed as one grouped operation; the failing envelope and untouched suffix
;; deliberately remain reserved for retry/recovery.
(defun consume-ordered (instance envelopes selector)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (is_function selector 1)
        ('true (consume-ordered-loop instance envelopes selector () 0 0 0))
        ('false (tuple 'error 'invalid_selector))))
    (error error)))

(defun consume-ordered-loop
  ((instance () _selector successful handled ack-only kept)
    (finish-ordered instance successful handled ack-only kept 0 'undefined))
  ((instance (cons envelope rest) selector successful handled ack-only kept)
    (case (safe-select selector envelope)
      ('ack
        (consume-ordered-loop instance rest selector (cons envelope successful)
                              handled (+ ack-only 1) kept))
      ('keep
        ;; `keep` is intentional consumption deferral, not a failure. Continue to
        ;; later independent deliveries while leaving this reservation outstanding.
        (consume-ordered-loop instance rest selector successful handled ack-only (+ kept 1)))
      ((tuple 'handle handler)
        (case (is_function handler 2)
          ('true
            (case (wiregrid_fast:delivery-event instance envelope)
              ((tuple 'ok event)
                (case (safe-handle handler event envelope)
                  ('ok
                    (consume-ordered-loop instance rest selector (cons envelope successful)
                                          (+ handled 1) ack-only kept))
                  ('drop
                    (consume-ordered-loop instance rest selector (cons envelope successful)
                                          (+ handled 1) ack-only kept))
                  ((tuple 'ok _value)
                    (consume-ordered-loop instance rest selector (cons envelope successful)
                                          (+ handled 1) ack-only kept))
                  (failure
                    (finish-ordered instance successful handled ack-only kept
                                    (+ 1 (: erlang length rest)) failure))))
              (failure
                (finish-ordered instance successful handled ack-only kept
                                (+ 1 (: erlang length rest)) failure))))
          ('false
            (finish-ordered instance successful handled ack-only kept
                            (+ 1 (: erlang length rest)) 'invalid_handler))))
      ((tuple 'error reason)
        (finish-ordered instance successful handled ack-only kept
                        (+ 1 (: erlang length rest)) (tuple 'selector_error reason)))
      (other
        (finish-ordered instance successful handled ack-only kept
                        (+ 1 (: erlang length rest)) (tuple 'invalid_selector_result other))))))

(defun finish-ordered
  ((_instance () handled ack-only kept remaining failure)
    (ordered-result handled ack-only kept remaining failure #M(acked 0 unknown 0)))
  ((instance successful handled ack-only kept remaining failure)
    (case (wiregrid_fast:ack-grouped instance (: lists reverse successful))
      ((tuple 'ok ack-result)
        (ordered-result handled ack-only kept remaining failure ack-result))
      (ack-error
        (tuple 'error #M(handled handled ack_only ack-only kept kept
                          remaining remaining failure failure ack_error ack-error))))))

(defun ordered-result
  ((handled ack-only kept 0 'undefined ack-result)
    (tuple 'ok #M(handled handled ack_only ack-only kept kept remaining 0 acks ack-result)))
  ((handled ack-only kept remaining failure ack-result)
    (tuple 'error #M(handled handled ack_only ack-only kept kept remaining remaining
                      failure failure acks ack-result))))

(defun safe-select (selector envelope)
  (try
    (funcall selector envelope)
    (catch
      ((tuple class reason _stack)
        (tuple 'error (tuple 'selector_failed class reason))))))

(defun safe-handle (handler event envelope)
  (try
    (funcall handler event envelope)
    (catch
      ((tuple class reason _stack)
        (tuple 'error (tuple 'handler_failed class reason))))))
