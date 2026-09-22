;; Runtime helpers for LFE applications using Wiregrid's high-throughput paths.
(defmodule wiregrid_fast
  (export all))

(defun publish-batch (instance topic events)
  (wiregrid_api:publish_batch instance topic events))

(defun publish-batch (instance topic events opts)
  (wiregrid_api:publish_batch instance topic events opts))

(defun publish-topics (instance topics event)
  (wiregrid_api:publish_topics instance topics event))

(defun publish-topics (instance topics event opts)
  (wiregrid_api:publish_topics instance topics event opts))

(defun send-sessions (instance sessions event)
  (wiregrid_api:send_sessions instance sessions event))

(defun send-sessions (instance sessions event opts)
  (wiregrid_api:send_sessions instance sessions event opts))

(defun send-users (instance users event)
  (wiregrid_api:send_users instance users event))

(defun send-users (instance users event opts)
  (wiregrid_api:send_users instance users event opts))

;; Bounded durable catch-up uses the canonical replay engine. Keeping this in
;; the fast façade lets macro-generated LFE workers bind a fixed instance/stream
;; without maintaining a separate replay implementation.
(defun replay-session (instance session stream)
  (wiregrid_api:replay_session instance session stream))
(defun replay-session (instance session stream opts)
  (wiregrid_api:replay_session instance session stream opts))

;; Delegate envelope validation to the canonical ABI. This preserves the fast
;; term-mode path while making malformed mailbox messages fail as data instead
;; of crashing an LFE consumer with `badmap`.
(defun delivery-event (instance envelope)
  (wiregrid_api:delivery_event instance envelope))

(defun ack-delivery (instance envelope)
  (case (envelope-ack envelope)
    ((tuple 'ok session delivery-id)
      (wiregrid_api:ack instance session delivery-id))
    (error error)))

;; Run a handler and ACK only after it reports success. This mirrors Wiregrid's
;; pressure model: consumption, not mere mailbox insertion, releases capacity.
(defun consume-and-ack (instance envelope handler)
  (case (delivery-event instance envelope)
    ((tuple 'ok event)
      (case (funcall handler event envelope)
        ('ok (ack-delivery instance envelope))
        ((tuple 'ok _) (ack-delivery instance envelope))
        (other other)))
    (error error)))

(defun ack-many (instance envelopes)
  (ack-many-loop instance envelopes 0))

(defun ack-many-loop (instance envelopes count)
  (case envelopes
    (() (tuple 'ok count))
    ((cons envelope rest)
      (case (ack-delivery instance envelope)
        ((tuple 'ok _pending) (ack-many-loop instance rest (+ count 1)))
        (error (tuple 'error count error))))))

(defun subscribe-many (instance session topics)
  (wiregrid_api:subscribe_many instance session topics))
(defun subscribe-many (instance session topics context)
  (wiregrid_api:subscribe_many instance session topics context))
(defun unsubscribe-many (instance session topics)
  (wiregrid_api:unsubscribe_many instance session topics))
(defun watch-many (instance session users)
  (wiregrid_api:watch_presence_many instance session users))
(defun watch-many (instance session users context)
  (wiregrid_api:watch_presence_many instance session users context))
(defun unwatch-many (instance session users)
  (wiregrid_api:unwatch_presence_many instance session users))
(defun join-many (instance session rooms)
  (wiregrid_api:join_rooms instance rooms session))
(defun join-many (instance session rooms opts)
  (wiregrid_api:join_rooms instance rooms session opts))
(defun leave-many (instance session rooms)
  (wiregrid_api:leave_rooms instance rooms session))

(defun prepare (instance event)
  (wiregrid_api:prepare instance event))
(defun publish-prepared (instance topic prepared)
  (wiregrid_api:publish_prepared instance topic prepared))
(defun send-session-prepared (instance session prepared)
  (wiregrid_api:send_session_prepared instance session prepared))
(defun send-user-prepared (instance user prepared)
  (wiregrid_api:send_user_prepared instance user prepared))

;; Prepared multi-target operations reuse one encoded payload across bounded
;; target sets. These are the preferred primitives for hot fanout workers.
(defun publish-topics-prepared (instance topics prepared)
  (wiregrid_api:publish_topics_prepared instance topics prepared))
(defun publish-topics-prepared (instance topics prepared opts)
  (wiregrid_api:publish_topics_prepared instance topics prepared opts))
(defun publish-rooms-prepared (instance rooms prepared)
  (wiregrid_api:publish_rooms_prepared instance rooms prepared))
(defun publish-rooms-prepared (instance rooms prepared opts)
  (wiregrid_api:publish_rooms_prepared instance rooms prepared opts))
(defun send-sessions-prepared (instance sessions prepared)
  (wiregrid_api:send_sessions_prepared instance sessions prepared))
(defun send-sessions-prepared (instance sessions prepared opts)
  (wiregrid_api:send_sessions_prepared instance sessions prepared opts))
(defun send-users-prepared (instance users prepared)
  (wiregrid_api:send_users_prepared instance users prepared))
(defun send-users-prepared (instance users prepared opts)
  (wiregrid_api:send_users_prepared instance users prepared opts))
(defun dispatch (instance targets event)
  (wiregrid_api:dispatch instance targets event))
(defun dispatch (instance targets event opts)
  (wiregrid_api:dispatch instance targets event opts))
(defun dispatch-prepared (instance targets prepared)
  (wiregrid_api:dispatch_prepared instance targets prepared))
(defun dispatch-prepared (instance targets prepared opts)
  (wiregrid_api:dispatch_prepared instance targets prepared opts))

;; Group ACKs by session so a burst of successfully processed deliveries uses
;; one bounded ack_many call per session instead of one runtime call per event.
(defun ack-grouped (instance envelopes)
  (case (collect-acks envelopes #M())
    ((tuple 'ok grouped) (ack-groups instance (: maps to_list grouped) 0 0))
    (error error)))

(defun collect-acks (envelopes grouped)
  (case envelopes
    (() (tuple 'ok grouped))
    ((cons envelope rest)
      (case (envelope-ack envelope)
        ((tuple 'ok session delivery-id)
          (let ((ids (: maps get session grouped ())))
            (collect-acks rest (: maps put session (cons delivery-id ids) grouped))))
        (error error)))))

(defun envelope-ack (envelope)
  (case (: maps find 'session_id envelope)
    ((tuple 'ok session)
      (case (: maps find 'delivery_id envelope)
        ((tuple 'ok delivery-id) (tuple 'ok session delivery-id))
        ('error (tuple 'error 'missing_delivery_id))))
    ('error (tuple 'error 'missing_session_id))))

(defun ack-groups (_instance groups acked unknown)
  (case groups
    (() (tuple 'ok #M(acked acked unknown unknown)))
    ((cons (tuple session ids) rest)
      (case (wiregrid_api:ack_many _instance session (: lists reverse ids))
        ((tuple 'ok result)
          (ack-groups _instance rest
                      (+ acked (: maps get 'acked result 0))
                      (+ unknown (: erlang length (: maps get 'unknown result ())))) )
        (error (tuple 'error #M(acked acked unknown unknown cause error)))))))


;; Reuse the instance's public batch budget in LFE hot helpers. This is a
;; bounded prefix walk, not `length/1`, so an oversized list stops as soon as
;; the configured limit is exceeded.
(defun validate-batch (instance envelopes)
  (case (wiregrid_api:limits instance)
    ((tuple 'ok limits)
      (let ((limit (: maps get 'max_batch_items limits 4096)))
        (bounded-list envelopes limit)))
    (error error)))

(defun validate-batch-size (instance batch-size)
  (case (wiregrid_api:limits instance)
    ((tuple 'ok limits)
      (let ((limit (: maps get 'max_batch_items limits 4096)))
        (case (andalso (is_integer batch-size) (> batch-size 0) (=< batch-size limit))
          ('true 'ok)
          ('false (tuple 'error 'invalid_batch_size)))))
    (error error)))

(defun bounded-list (value limit)
  (case (andalso (is_list value) (is_integer limit) (>= limit 0))
    ('true (bounded-list-loop value limit))
    ('false (tuple 'error 'invalid_batch))))

(defun bounded-list-loop (() _remaining) 'ok)
(defun bounded-list-loop (_items 0) (tuple 'error 'batch_too_large))
(defun bounded-list-loop ((cons _item rest) remaining)
  (bounded-list-loop rest (- remaining 1)))
