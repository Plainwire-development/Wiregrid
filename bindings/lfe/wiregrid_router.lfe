;; High-throughput LFE delivery routing over the stable Wiregrid envelope.
;; Exact topic routing is a map lookup; decoding occurs only after a route is
;; selected. `handle-event/4` deliberately does not ACK so bounded workers can
;; group acknowledgements through the canonical runtime.
(defmodule wiregrid_router
  (export all))


;; Validate fixed route tables once before a hot worker/selector loop. Route
;; maps are application-owned but still bounded so a mistaken giant map cannot
;; turn setup into an unbounded validation walk.
(defun valid-routes (routes default-handler)
  (cond
    ((not (is_map routes)) (tuple 'error 'invalid_routes))
    ((> (: maps size routes) 4096) (tuple 'error 'too_many_routes))
    ((andalso (/= default-handler 'undefined)
              (not (is_function default-handler 2)))
      (tuple 'error 'invalid_default_handler))
    ((not (: lists all (lambda (handler) (is_function handler 2))
                       (: maps values routes)))
      (tuple 'error 'invalid_route_handler))
    ('true 'ok)))

(defun route (instance envelope routes)
  (route instance envelope routes 'undefined))

(defun route (instance envelope routes default-handler)
  (case (valid-routes routes default-handler)
    ('ok (route-valid instance envelope routes default-handler))
    (error error)))

(defun route-valid (instance envelope routes default-handler)
  (case (wiregrid_fast:delivery-event instance envelope)
    ((tuple 'ok event)
      (case (handle-event event envelope routes default-handler)
        ('ok (wiregrid_fast:ack-delivery instance envelope))
        ((tuple 'ok _) (wiregrid_fast:ack-delivery instance envelope))
        ('drop (wiregrid_fast:ack-delivery instance envelope))
        (other other)))
    (error error)))

;; Route a delivery that has already been decoded by a batch worker. This is
;; the preferred path for wiregrid_worker because it avoids duplicate decode
;; and lets Wiregrid.Consumer group ACKs after the batch completes.
(defun handle-event (event envelope routes)
  (handle-event event envelope routes 'undefined))

(defun handle-event (event envelope routes default-handler)
  (case (handler-for envelope routes default-handler)
    ((tuple 'ok handler) (funcall handler event envelope))
    (error error)))

(defun handler-for (envelope routes default-handler)
  (case (: maps find 'topic envelope)
    ((tuple 'ok topic)
      (case (: maps find topic routes)
        ((tuple 'ok handler) (tuple 'ok handler))
        ('error (default-route default-handler))))
    ('error (tuple 'error 'missing_delivery_topic))))

(defun default-route
  (('undefined) (tuple 'error 'no_route))
  ((handler) (tuple 'ok handler)))

(defun route-many (instance envelopes routes)
  (route-many instance envelopes routes 'undefined))

(defun route-many (instance envelopes routes default-handler)
  ;; Delegate to the selector so successful deliveries are ACKed once per
  ;; session instead of issuing one runtime call per envelope. The selector
  ;; validates the bounded batch and route table once, decodes each delivery
  ;; once, and preserves reservations for failed handlers.
  (wiregrid_selector:consume-routed instance envelopes routes default-handler))

(defun topic (envelope)
  (: maps get 'topic envelope 'undefined))
(defun delivery-class (envelope)
  (: maps get 'class envelope 'undefined))
(defun delivery-id (envelope)
  (: maps get 'delivery_id envelope 'undefined))
(defun session-id (envelope)
  (: maps get 'session_id envelope 'undefined))
