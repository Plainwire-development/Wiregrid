;; Session-bound LFE convenience API.
;;
;; The actor map contains no cached permission state. Every operation crosses
;; wiregrid_api, so authorization, drain state, validation and backpressure stay
;; canonical. Authenticated publish/send calls inject session_id and reject an
;; attempt to override it in an option proplist.
(defmodule wiregrid_actor
  (export all))

(defun new (instance session)
  (case (wiregrid_api:session instance session)
    ((tuple 'ok info)
      (tuple 'ok #M(instance instance
                     session_id session
                     user_id (: maps get 'user_id info 'undefined))))
    (error error)))

(defun connect (instance user pid)
  (connect instance user pid ()))
(defun connect (instance user pid opts)
  (case (wiregrid_api:connect instance user pid opts)
    ((tuple 'ok session)
      (tuple 'ok #M(instance instance session_id session user_id user)))
    (error error)))

(defun connect-resumable (instance user pid)
  (connect-resumable instance user pid ()))
(defun connect-resumable (instance user pid opts)
  (case (wiregrid_api:connect_resumable instance user pid opts)
    ((tuple 'ok session token)
      (tuple 'ok #M(instance instance session_id session user_id user) token))
    (error error)))

(defun resume (instance user pid token)
  (resume instance user pid token ()))
(defun resume (instance user pid token opts)
  (case (wiregrid_api:resume_session instance user pid token opts)
    ((tuple 'ok result)
      (tuple 'ok
             #M(instance instance
                session_id (: maps get 'session_id result)
                user_id user)
             (: maps get 'resume_token result)
             (: maps get 'restored result #M())))
    (error error)))

(defun instance (actor) (: maps get 'instance actor))
(defun session-id (actor) (: maps get 'session_id actor))
(defun user-id (actor) (: maps get 'user_id actor 'undefined))

(defun session (actor)
  (wiregrid_api:session (instance actor) (session-id actor)))
(defun disconnect (actor)
  (wiregrid_api:disconnect (instance actor) (session-id actor)))
(defun disconnect (actor reason)
  (wiregrid_api:disconnect (instance actor) (session-id actor) reason))
(defun pending (actor)
  (wiregrid_api:pending (instance actor) (session-id actor)))
(defun ack (actor delivery-id)
  (wiregrid_api:ack (instance actor) (session-id actor) delivery-id))
(defun ack-many (actor delivery-ids)
  (wiregrid_api:ack_many (instance actor) (session-id actor) delivery-ids))
(defun set-metadata (actor metadata)
  (wiregrid_api:set_session_metadata (instance actor) (session-id actor) metadata))

;; Topology.
(defun subscribe (actor topic)
  (wiregrid_api:subscribe (instance actor) (session-id actor) topic))
(defun subscribe (actor topic context)
  (wiregrid_api:subscribe (instance actor) (session-id actor) topic context))
(defun unsubscribe (actor topic)
  (wiregrid_api:unsubscribe (instance actor) (session-id actor) topic))
(defun subscribe-many (actor topics)
  (wiregrid_api:subscribe_many (instance actor) (session-id actor) topics))
(defun subscribe-many (actor topics context)
  (wiregrid_api:subscribe_many (instance actor) (session-id actor) topics context))
(defun unsubscribe-many (actor topics)
  (wiregrid_api:unsubscribe_many (instance actor) (session-id actor) topics))
(defun sync-subscriptions (actor topics)
  (wiregrid_api:sync_subscriptions (instance actor) (session-id actor) topics))
(defun sync-subscriptions (actor topics context)
  (wiregrid_api:sync_subscriptions (instance actor) (session-id actor) topics context))
(defun sync-topology (actor topology)
  (wiregrid_api:sync_topology (instance actor) (session-id actor) topology))
(defun sync-topology (actor topology opts)
  (wiregrid_api:sync_topology (instance actor) (session-id actor) topology opts))

;; Bounded actor-local inspection.
(defun state (actor)
  (wiregrid_api:session_state (instance actor) (session-id actor)))
(defun state (actor limit)
  (wiregrid_api:session_state (instance actor) (session-id actor) limit))
(defun subscriptions (actor)
  (wiregrid_api:subscriptions (instance actor) (session-id actor)))
(defun subscriptions (actor limit)
  (wiregrid_api:subscriptions (instance actor) (session-id actor) limit))
(defun rooms (actor)
  (wiregrid_api:session_rooms (instance actor) (session-id actor)))
(defun rooms (actor limit)
  (wiregrid_api:session_rooms (instance actor) (session-id actor) limit))
(defun presence-watches (actor)
  (wiregrid_api:presence_watches (instance actor) (session-id actor)))
(defun presence-watches (actor limit)
  (wiregrid_api:presence_watches (instance actor) (session-id actor) limit))

;; Presence.
(defun set-presence (actor status)
  (wiregrid_api:set_presence (instance actor) (session-id actor) status))
(defun set-presence (actor status metadata)
  (wiregrid_api:set_presence (instance actor) (session-id actor) status metadata))
(defun watch-presence (actor user)
  (wiregrid_api:watch_presence (instance actor) (session-id actor) user))
(defun watch-presence (actor user context)
  (wiregrid_api:watch_presence (instance actor) (session-id actor) user context))
(defun unwatch-presence (actor user)
  (wiregrid_api:unwatch_presence (instance actor) (session-id actor) user))
(defun sync-presence-watches (actor users)
  (wiregrid_api:sync_presence_watches (instance actor) (session-id actor) users))

;; Rooms.
(defun join-room (actor room)
  (wiregrid_api:join_room (instance actor) room (session-id actor)))
(defun join-room (actor room opts)
  (wiregrid_api:join_room (instance actor) room (session-id actor) opts))
(defun leave-room (actor room)
  (wiregrid_api:leave_room (instance actor) room (session-id actor)))
(defun join-rooms (actor rooms)
  (wiregrid_api:join_rooms (instance actor) rooms (session-id actor)))
(defun join-rooms (actor rooms opts)
  (wiregrid_api:join_rooms (instance actor) rooms (session-id actor) opts))
(defun leave-rooms (actor rooms)
  (wiregrid_api:leave_rooms (instance actor) rooms (session-id actor)))
(defun sync-rooms (actor rooms)
  (wiregrid_api:sync_rooms (instance actor) (session-id actor) rooms))
(defun sync-rooms (actor rooms opts)
  (wiregrid_api:sync_rooms (instance actor) (session-id actor) rooms opts))
(defun set-room-metadata (actor room metadata)
  (wiregrid_api:set_room_metadata (instance actor) room (session-id actor) metadata))
(defun set-room-metadata (actor room metadata opts)
  (wiregrid_api:set_room_metadata (instance actor) room (session-id actor) metadata opts))
(defun set-room-ttl (actor room ttl-ms)
  (wiregrid_api:set_room_ttl (instance actor) room (session-id actor) ttl-ms))

;; Ephemeral state and signaling.
(defun typing (actor topic)
  (wiregrid_api:typing (instance actor) (session-id actor) topic))
(defun typing (actor topic opts)
  (wiregrid_api:typing (instance actor) (session-id actor) topic opts))
(defun activity (actor topic kind value)
  (wiregrid_api:activity (instance actor) (session-id actor) topic kind value))
(defun activity (actor topic kind value opts)
  (wiregrid_api:activity (instance actor) (session-id actor) topic kind value opts))
(defun receipt (actor receipt)
  (wiregrid_api:receipt (instance actor) (session-id actor) receipt))
(defun receipt (actor receipt opts)
  (wiregrid_api:receipt (instance actor) (session-id actor) receipt opts))
(defun signal (actor room kind payload)
  (wiregrid_api:signal (instance actor) room (session-id actor) kind payload))
(defun signal (actor room kind payload opts)
  (wiregrid_api:signal (instance actor) room (session-id actor) kind payload opts))
(defun request-session (actor target event)
  (wiregrid_api:request_session (instance actor) (session-id actor) target event))
(defun request-session (actor target event opts)
  (wiregrid_api:request_session (instance actor) (session-id actor) target event opts))
(defun reply (actor request-envelope event)
  (wiregrid_api:reply (instance actor) (session-id actor) request-envelope event))
(defun reply (actor request-envelope event opts)
  (wiregrid_api:reply (instance actor) (session-id actor) request-envelope event opts))

;; Session-keyed hot-path rate limiting. These helpers are useful for per-client
;; publish/frame/application operation budgets without callers having to repeat
;; the actor session identifier. Policy/options remain canonical Wiregrid data.
;; Durable catch-up for the actor's own live session. Authorization is still
;; evaluated by Wiregrid against this session before storage is read/delivered.
(defun replay-session (actor stream)
  (wiregrid_api:replay_session (instance actor) (session-id actor) stream))
(defun replay-session (actor stream opts)
  (wiregrid_api:replay_session (instance actor) (session-id actor) stream opts))

(defun rate-limit (actor bucket limit window-ms)
  (wiregrid_api:rate_limit (instance actor) bucket (session-id actor) limit window-ms))
(defun rate-limit (actor bucket limit window-ms opts)
  (wiregrid_api:rate_limit (instance actor) bucket (session-id actor) limit window-ms opts))

;; Authenticated publication. Caller-supplied session_id is rejected rather
;; than overwritten so an application cannot accidentally believe it is using a
;; different identity than the one Wiregrid authorizes.
(defun publish (actor topic event)
  (publish actor topic event ()))
(defun publish (actor topic event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish (instance actor) topic event bound))))

(defun publish-room (actor room event)
  (publish-room actor room event ()))
(defun publish-room (actor room event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_room (instance actor) room event bound))))

(defun publish-topics (actor topics event)
  (publish-topics actor topics event ()))
(defun publish-topics (actor topics event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_topics (instance actor) topics event bound))))

(defun publish-prepared (actor topic prepared)
  (publish-prepared actor topic prepared ()))
(defun publish-prepared (actor topic prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_prepared (instance actor) topic prepared bound))))
(defun publish-topics-prepared (actor topics prepared)
  (publish-topics-prepared actor topics prepared ()))
(defun publish-topics-prepared (actor topics prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_topics_prepared (instance actor) topics prepared bound))))
(defun publish-room-prepared (actor room prepared)
  (publish-room-prepared actor room prepared ()))
(defun publish-room-prepared (actor room prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_room_prepared (instance actor) room prepared bound))))
(defun publish-rooms (actor rooms event)
  (publish-rooms actor rooms event ()))
(defun publish-rooms (actor rooms event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_rooms (instance actor) rooms event bound))))
(defun publish-rooms-prepared (actor rooms prepared)
  (publish-rooms-prepared actor rooms prepared ()))
(defun publish-rooms-prepared (actor rooms prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:publish_rooms_prepared (instance actor) rooms prepared bound))))

(defun send-user (actor user event)
  (send-user actor user event ()))
(defun send-user (actor user event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_user (instance actor) user event bound))))

(defun send-session (actor target event)
  (send-session actor target event ()))
(defun send-session (actor target event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_session (instance actor) target event bound))))

(defun send-user-prepared (actor user prepared)
  (send-user-prepared actor user prepared ()))
(defun send-user-prepared (actor user prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_user_prepared (instance actor) user prepared bound))))
(defun send-session-prepared (actor target prepared)
  (send-session-prepared actor target prepared ()))
(defun send-session-prepared (actor target prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_session_prepared (instance actor) target prepared bound))))
(defun send-users (actor users event)
  (send-users actor users event ()))
(defun send-users (actor users event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_users (instance actor) users event bound))))
(defun send-sessions (actor sessions event)
  (send-sessions actor sessions event ()))
(defun send-sessions (actor sessions event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_sessions (instance actor) sessions event bound))))

(defun compile-dispatch (actor targets)
  (wiregrid_api:compile_dispatch (instance actor) targets))

(defun dispatch (actor targets event)
  (dispatch actor targets event ()))
(defun dispatch (actor targets event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:dispatch (instance actor) targets event bound))))

(defun dispatch-prepared (actor targets prepared)
  (dispatch-prepared actor targets prepared ()))
(defun dispatch-prepared (actor targets prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:dispatch_prepared (instance actor) targets prepared bound))))
(defun dispatch-plan (actor plan event)
  (dispatch-plan actor plan event ()))
(defun dispatch-plan (actor plan event opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:dispatch_plan (instance actor) plan event bound))))
(defun dispatch-plan-prepared (actor plan prepared)
  (dispatch-plan-prepared actor plan prepared ()))
(defun dispatch-plan-prepared (actor plan prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:dispatch_plan_prepared (instance actor) plan prepared bound))))


;; Remaining prepared multi-target helpers not covered above.
(defun send-users-prepared (actor users prepared)
  (send-users-prepared actor users prepared ()))
(defun send-users-prepared (actor users prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_users_prepared (instance actor) users prepared bound))))

(defun send-sessions-prepared (actor targets prepared)
  (send-sessions-prepared actor targets prepared ()))
(defun send-sessions-prepared (actor targets prepared opts)
  (with-auth-opts actor opts
    (lambda (bound)
      (wiregrid_api:send_sessions_prepared (instance actor) targets prepared bound))))

(defun watch-presence-many (actor users)
  (wiregrid_api:watch_presence_many (instance actor) (session-id actor) users))
(defun watch-presence-many (actor users context)
  (wiregrid_api:watch_presence_many (instance actor) (session-id actor) users context))
(defun unwatch-presence-many (actor users)
  (wiregrid_api:unwatch_presence_many (instance actor) (session-id actor) users))
(defun sync-presence-watches (actor users context)
  (wiregrid_api:sync_presence_watches (instance actor) (session-id actor) users context))

(defun with-auth-opts (actor opts fun)
  (cond
    ((not (is_list opts)) (tuple 'error 'invalid_options))
    ((: lists keymember 'session_id 1 opts) (tuple 'error 'actor_session_override))
    ('true (funcall fun (cons (tuple 'session_id (session-id actor)) opts)))))
