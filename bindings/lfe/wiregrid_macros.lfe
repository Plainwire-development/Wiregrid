;; Compile-time helpers for high-throughput LFE Wiregrid applications.
;; Generated code targets the stable wiregrid_api ABI directly; macros never
;; bypass Wiregrid validation, authorization, backpressure or resource limits.
(defmodule wiregrid_macros
  (export-macro topic-user topic-channel topic-thread topic-room topic-game
                topic-document topic-custom
                target-topic target-room target-user target-session
                connect-encoded connect-resumable-encoded
                publish-durable publish-ephemeral publish-local-durable
                publish-local-ephemeral publish-room-durable publish-room-ephemeral
                dispatch-durable dispatch-ephemeral dispatch-local-durable
                dispatch-local-ephemeral
                send-user-durable send-user-ephemeral
                send-user-local-durable send-user-local-ephemeral
                send-session-durable send-session-ephemeral
                request-durable request-ephemeral reply-durable reply-ephemeral
                signal-ring signal-accept signal-decline signal-cancel
                signal-offer signal-answer signal-ice signal-leave
                signal-reconnect signal-membership ack-envelope
                defpublisher defephemeral-publisher defbatch-publisher
                defmultitopic-publisher defroom-publisher
                defprepared-publisher defprepared-multitopic-publisher
                defprepared-room-publisher defprepared-session-sender
                defprepared-user-sender defpreparing-publisher
                defdispatcher defprepared-dispatcher
                defdispatch-plan defplan-dispatcher defplan-prepared-dispatcher
                defsession-sender defuser-sender deflocal-user-sender
                defrequester defreplier defreplayer
                defsubscription-set defpresence-watch-set defroom-set
                defconsumer defencoded-consumer defbatch-consumer
                defrouter-consumer defpipeline-consumer defeffects-consumer
                defworker defstrict-worker defpriority-worker defstrict-priority-worker
                defrouter-worker defstrict-router-worker
                defpipeline-worker defstrict-pipeline-worker
                defbatch-router-consumer defclass-batch-consumer
                defcorrelated-batch-consumer defclass-worker defstrict-class-worker
                defcorrelated-worker defstrict-correlated-worker
                deffold-consumer
                defsync-subscriptions defsync-presence-watches defsync-rooms defsync-topology
                defcompiled-router defcompiled-router-worker defstrict-compiled-router-worker
                defcompiled-effects defcompiled-effects-worker defstrict-compiled-effects-worker
                defcompiled-classifier defcompiled-class-worker defstrict-compiled-class-worker
                defcompiled-correlation defcompiled-correlation-worker defstrict-compiled-correlation-worker
                defcompiled-topic-classifier defcompiled-topic-class-worker defstrict-compiled-topic-class-worker
                defcompiled-topic-correlation defcompiled-topic-correlation-worker defstrict-compiled-topic-correlation-worker
                defcompiled-event-router defcompiled-event-router-worker defstrict-compiled-event-router-worker
                defcompiled-router-effects defcompiled-router-effects-worker defstrict-compiled-router-effects-worker
                defcompiled-event-router-effects defcompiled-event-router-effects-worker defstrict-compiled-event-router-effects-worker
                defcompiled-delivery-matrix defcompiled-delivery-matrix-worker defstrict-compiled-delivery-matrix-worker
                defworker-child-spec defpriority-worker-child-spec
                deffixed-window-limit deftoken-bucket-limit
                defcompiled-kernel defcompiled-kernel-worker defstrict-compiled-kernel-worker
                defmicrobatch-kernel-worker defstrict-microbatch-kernel-worker
                defcompiled-kernel-matrix defcompiled-kernel-matrix-worker
                defstrict-compiled-kernel-matrix-worker defmicrobatch-kernel-matrix-worker
                defstrict-microbatch-kernel-matrix-worker
                defcompiled-kernel-correlation defcompiled-kernel-correlation-worker
                defstrict-compiled-kernel-correlation-worker defmicrobatch-kernel-correlation-worker
                defstrict-microbatch-kernel-correlation-worker
                defcompiled-ordered-kernel defcompiled-ordered-kernel-worker
                defstrict-compiled-ordered-kernel-worker
                defkernel-child-spec
                defcompiled-authorizer defprojection-consumer
                defstrict-projection-consumer defcompiled-command-handler
                defnamed-command-handler defcompiled-dispatch-policy
                deflane-consumer deflane-worker defstrict-lane-worker
                defsession-lane-worker deftopic-lane-worker defrequest-lane-worker
                defcoalescing-consumer defcoalescing-worker
                deftopic-coalescing-worker defsession-topic-coalescing-worker
                defcoalesced-lane-consumer defcoalesced-lane-worker
                defsession-coalesced-lane-worker defrequest-coalesced-lane-worker))

;; Compile-time constructors emit the exact ordinary tuples used by the ABI.
(defmacro topic-user (id) `(tuple 'user ,id))
(defmacro topic-channel (id) `(tuple 'channel ,id))
(defmacro topic-thread (id) `(tuple 'thread ,id))
(defmacro topic-room (id) `(tuple 'room ,id))
(defmacro topic-game (id) `(tuple 'game ,id))
(defmacro topic-document (id) `(tuple 'document ,id))
(defmacro topic-custom (namespace value) `(tuple 'custom ,namespace ,value))

(defmacro target-topic (topic) `(tuple 'topic ,topic))
(defmacro target-room (room) `(tuple 'room ,room))
(defmacro target-user (user) `(tuple 'user ,user))
(defmacro target-session (session) `(tuple 'session ,session))

;; Encoded delivery avoids copying a decoded event term into every recipient
;; mailbox. The consumer can defer decode until it actually handles the event.
(defmacro connect-encoded (instance user pid)
  `(: wiregrid_api connect ,instance ,user ,pid
      (list (tuple 'delivery_format 'encoded))))

(defmacro connect-resumable-encoded (instance user pid)
  `(: wiregrid_api connect_resumable ,instance ,user ,pid
      (list (tuple 'delivery_format 'encoded))))

;; Common fixed-class operations compile their option lists once at the call
;; site while still crossing the normal Wiregrid public boundary.
(defmacro publish-durable (instance topic event)
  `(: wiregrid_api publish ,instance ,topic ,event
      (list (tuple 'class 'durable))))
(defmacro publish-ephemeral (instance topic event)
  `(: wiregrid_api publish ,instance ,topic ,event
      (list (tuple 'class 'ephemeral))))
(defmacro publish-local-durable (instance topic event)
  `(: wiregrid_api publish ,instance ,topic ,event
      (list (tuple 'class 'durable) (tuple 'cluster 'false))))
(defmacro publish-local-ephemeral (instance topic event)
  `(: wiregrid_api publish ,instance ,topic ,event
      (list (tuple 'class 'ephemeral) (tuple 'cluster 'false))))

(defmacro publish-room-durable (instance room event)
  `(: wiregrid_api publish_room ,instance ,room ,event
      (list (tuple 'class 'durable))))
(defmacro publish-room-ephemeral (instance room event)
  `(: wiregrid_api publish_room ,instance ,room ,event
      (list (tuple 'class 'ephemeral))))

(defmacro dispatch-durable (instance targets event)
  `(: wiregrid_api dispatch ,instance ,targets ,event
      (list (tuple 'class 'durable))))
(defmacro dispatch-ephemeral (instance targets event)
  `(: wiregrid_api dispatch ,instance ,targets ,event
      (list (tuple 'class 'ephemeral))))
(defmacro dispatch-local-durable (instance targets event)
  `(: wiregrid_api dispatch ,instance ,targets ,event
      (list (tuple 'class 'durable) (tuple 'cluster 'false))))
(defmacro dispatch-local-ephemeral (instance targets event)
  `(: wiregrid_api dispatch ,instance ,targets ,event
      (list (tuple 'class 'ephemeral) (tuple 'cluster 'false))))

(defmacro send-user-durable (instance user event)
  `(: wiregrid_api send_user ,instance ,user ,event
      (list (tuple 'class 'durable))))
(defmacro send-user-ephemeral (instance user event)
  `(: wiregrid_api send_user ,instance ,user ,event
      (list (tuple 'class 'ephemeral))))
(defmacro send-user-local-durable (instance user event)
  `(: wiregrid_api send_user ,instance ,user ,event
      (list (tuple 'class 'durable) (tuple 'cluster 'false))))
(defmacro send-user-local-ephemeral (instance user event)
  `(: wiregrid_api send_user ,instance ,user ,event
      (list (tuple 'class 'ephemeral) (tuple 'cluster 'false))))
(defmacro send-session-durable (instance session event)
  `(: wiregrid_api send_session ,instance ,session ,event
      (list (tuple 'class 'durable))))
(defmacro send-session-ephemeral (instance session event)
  `(: wiregrid_api send_session ,instance ,session ,event
      (list (tuple 'class 'ephemeral))))

(defmacro request-durable (instance requester target event)
  `(: wiregrid_api request_session ,instance ,requester ,target ,event
      (list (tuple 'class 'durable))))
(defmacro request-ephemeral (instance requester target event)
  `(: wiregrid_api request_session ,instance ,requester ,target ,event
      (list (tuple 'class 'ephemeral))))
(defmacro reply-durable (instance replier request-envelope event)
  `(: wiregrid_api reply ,instance ,replier ,request-envelope ,event
      (list (tuple 'class 'durable))))
(defmacro reply-ephemeral (instance replier request-envelope event)
  `(: wiregrid_api reply ,instance ,replier ,request-envelope ,event
      (list (tuple 'class 'ephemeral))))

;; Signaling atoms are closed at compile time instead of being built from
;; untrusted strings.
(defmacro signal-ring (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'ring ,payload))
(defmacro signal-accept (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'accept ,payload))
(defmacro signal-decline (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'decline ,payload))
(defmacro signal-cancel (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'cancel ,payload))
(defmacro signal-offer (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'offer ,payload))
(defmacro signal-answer (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'answer ,payload))
(defmacro signal-ice (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'ice_candidate ,payload))
(defmacro signal-leave (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'leave ,payload))
(defmacro signal-reconnect (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'reconnect ,payload))
(defmacro signal-membership (instance room session payload)
  `(: wiregrid_api signal ,instance ,room ,session 'membership ,payload))

(defmacro ack-envelope (instance envelope)
  `(: wiregrid_api ack ,instance
      (: maps get 'session_id ,envelope)
      (: maps get 'delivery_id ,envelope)))

;; Hot function generators. Fixed instances/topics/targets become constants in
;; the generated BEAM code, while event data stays a normal runtime argument.
(defmacro defpublisher (name instance topic)
  `(defun ,name (event)
     (: wiregrid_api publish ,instance ,topic event)))
(defmacro defephemeral-publisher (name instance topic)
  `(defun ,name (event)
     (: wiregrid_api publish ,instance ,topic event
       (list (tuple 'class 'ephemeral)))))
(defmacro defbatch-publisher (name instance topic)
  `(defun ,name (events)
     (: wiregrid_api publish_batch ,instance ,topic events)))
(defmacro defmultitopic-publisher (name instance topics)
  `(defun ,name (event)
     (: wiregrid_api publish_topics ,instance ,topics event)))
(defmacro defroom-publisher (name instance room)
  `(defun ,name (event)
     (: wiregrid_api publish_room ,instance ,room event)))

;; Prepared generators eliminate codec work from repeated fanout calls.
(defmacro defprepared-publisher (name instance topic)
  `(defun ,name (prepared)
     (: wiregrid_api publish_prepared ,instance ,topic prepared)))
(defmacro defprepared-multitopic-publisher (name instance topics)
  `(defun ,name (prepared)
     (: wiregrid_api publish_topics_prepared ,instance ,topics prepared)))
(defmacro defprepared-room-publisher (name instance room)
  `(defun ,name (prepared)
     (: wiregrid_api publish_room_prepared ,instance ,room prepared)))
(defmacro defprepared-session-sender (name instance session)
  `(defun ,name (prepared)
     (: wiregrid_api send_session_prepared ,instance ,session prepared)))
(defmacro defprepared-user-sender (name instance user)
  `(defun ,name (prepared)
     (: wiregrid_api send_user_prepared ,instance ,user prepared)))

(defmacro defpreparing-publisher (name instance topic)
  `(defun ,name (event)
     (case (: wiregrid_api prepare ,instance event)
       ((tuple 'ok prepared)
         (: wiregrid_api publish_prepared ,instance ,topic prepared))
       (error error))))

(defmacro defdispatcher (name instance targets)
  `(defun ,name (event)
     (: wiregrid_api dispatch ,instance ,targets event)))
(defmacro defprepared-dispatcher (name instance targets)
  `(defun ,name (prepared)
     (: wiregrid_api dispatch_prepared ,instance ,targets prepared)))

;; Restart-aware plan helpers keep plan state explicit in the application. The
;; generated dispatchers return {ok, NewState, Result}; callers retain NewState
;; so a plan transparently refreshed after an instance restart is reused.
(defmacro defdispatch-plan (name instance targets)
  `(defun ,name ()
     (: wiregrid_plan new ,instance ,targets)))
(defmacro defplan-dispatcher (name)
  `(defun ,name (state event)
     (: wiregrid_plan dispatch state event)))
(defmacro defplan-prepared-dispatcher (name)
  `(defun ,name (state prepared)
     (: wiregrid_plan dispatch-prepared state prepared)))

(defmacro defsession-sender (name instance session)
  `(defun ,name (event)
     (: wiregrid_api send_session ,instance ,session event)))
(defmacro defuser-sender (name instance user)
  `(defun ,name (event)
     (: wiregrid_api send_user ,instance ,user event)))
(defmacro deflocal-user-sender (name instance user)
  `(defun ,name (event)
     (: wiregrid_api send_user ,instance ,user event
       (list (tuple 'cluster 'false)))))
(defmacro defrequester (name instance requester target)
  `(defun ,name (event)
     (: wiregrid_api request_session ,instance ,requester ,target event)))
(defmacro defreplier (name instance replier)
  `(defun ,name (request-envelope event)
     (: wiregrid_api reply ,instance ,replier request-envelope event)))

;; Compile fixed topology bootstraps into one bounded Runtime mutation each.
(defmacro defsubscription-set (name instance session topics)
  `(defun ,name ()
     (: wiregrid_api subscribe_many ,instance ,session ,topics)))
(defmacro defpresence-watch-set (name instance session users)
  `(defun ,name ()
     (: wiregrid_api watch_presence_many ,instance ,session ,users)))
(defmacro defroom-set (name instance session rooms)
  `(defun ,name ()
     (: wiregrid_api join_rooms ,instance ,rooms ,session)))

;; Consumer generators preserve the central backpressure invariant: capacity is
;; released only after application handling succeeds (or intentionally drops).
(defmacro defconsumer (name instance handler)
  `(defun ,name (envelope)
     (: wiregrid_fast consume-and-ack ,instance envelope ,handler)))
(defmacro defencoded-consumer (name instance handler)
  `(defun ,name (envelope)
     (: wiregrid_fast consume-and-ack ,instance envelope ,handler)))
(defmacro defbatch-consumer (name instance handler)
  `(defun ,name (envelopes)
     (: wiregrid_pipeline consume-many ,instance envelopes ,handler)))
(defmacro defrouter-consumer (name instance routes default-handler)
  `(defun ,name (envelope)
     (: wiregrid_router route ,instance envelope ,routes ,default-handler)))
(defmacro defpipeline-consumer (name instance stages)
  `(defun ,name (envelope)
     (: wiregrid_pipeline consume ,instance envelope ,stages)))
(defmacro defeffects-consumer (name instance stages)
  `(defun ,name (envelope)
     (: wiregrid_pipeline consume-effects ,instance envelope ,stages)))

;; Generate a fixed-instance bounded burst worker starter. The generated function
;; does not create a second runtime; it starts wiregrid_worker over the stable ABI.
(defmacro defworker (name instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link ,instance ,handler ,batch-size)))

(defmacro defstrict-worker (name instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link ,instance ,handler ,batch-size 'crash)))

(defmacro defpriority-worker (name instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_priority ,instance ,handler ,batch-size)))

(defmacro defstrict-priority-worker (name instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_priority ,instance ,handler ,batch-size 'crash)))


;; Macro-generated fixed workers are where LFE earns its place in the hot path:
;; routes/stages/instance/batch policy become BEAM literals, while actual
;; validation, delivery accounting and ACK ownership remain canonical Wiregrid.
(defmacro defrouter-worker (name instance routes default-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_router ,instance ,routes ,default-handler ,batch-size)))

(defmacro defstrict-router-worker (name instance routes default-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_router ,instance ,routes ,default-handler ,batch-size 'crash)))

(defmacro defpipeline-worker (name instance stages batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_pipeline ,instance ,stages ,batch-size)))

(defmacro defstrict-pipeline-worker (name instance stages batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_pipeline ,instance ,stages ,batch-size 'crash)))


;; Batch-specialized selectors decode each envelope once and ACK successful
;; work in grouped per-session calls. Fixed routes/handlers become literals in
;; the generated function and avoid rebuilding selector configuration per batch.
(defmacro defbatch-router-consumer (name instance routes default-handler)
  `(defun ,name (envelopes)
     (: wiregrid_selector consume-routed ,instance envelopes ,routes ,default-handler)))

(defmacro defclass-batch-consumer (name instance durable-handler ephemeral-handler)
  `(defun ,name (envelopes)
     (: wiregrid_selector consume-classified ,instance envelopes
        ,durable-handler ,ephemeral-handler)))

(defmacro defcorrelated-batch-consumer (name instance request-handler reply-handler default-handler)
  `(defun ,name (envelopes)
     (: wiregrid_selector consume-correlated ,instance envelopes
        ,request-handler ,reply-handler ,default-handler)))


(defmacro defclass-worker (name instance durable-handler ephemeral-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_classified ,instance
        ,durable-handler ,ephemeral-handler ,batch-size)))

(defmacro defstrict-class-worker (name instance durable-handler ephemeral-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_classified ,instance
        ,durable-handler ,ephemeral-handler ,batch-size 'crash)))

(defmacro defcorrelated-worker (name instance request-handler reply-handler default-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_correlated ,instance
        ,request-handler ,reply-handler ,default-handler ,batch-size)))

(defmacro defstrict-correlated-worker (name instance request-handler reply-handler default-handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker start_link_correlated ,instance
        ,request-handler ,reply-handler ,default-handler ,batch-size 'crash)))


;; Stateful fold consumers compile a fixed instance/reducer/initial state into
;; one direct helper. The reducer still receives the decoded event and original
;; envelope, and successful-prefix ACKs remain grouped by session.
(defmacro deffold-consumer (name instance reducer initial)
  `(defun ,name (envelopes)
     (: wiregrid_fold consume ,instance envelopes ,initial ,reducer)))

;; Generate fixed OTP child-spec helpers for supervised LFE consumers. The
;; child-spec id remains explicit and compile-time visible, while Wiregrid
;; validates handler/batch/failure options when the helper is called.
(defmacro defworker-child-spec (name id instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker child_spec ,id ,instance ,handler ,batch-size)))

(defmacro defpriority-worker-child-spec (name id instance handler batch-size)
  `(defun ,name ()
     (: wiregrid_worker priority_child_spec ,id ,instance ,handler ,batch-size)))


;; Desired-state topology macros. Unlike the older bootstrap helpers these use
;; the Runtime's transactional-ish reconcile path: additions happen first and
;; are rolled back on failure, then obsolete edges are removed.
(defmacro defsync-subscriptions (name instance session topics)
  `(defun ,name ()
     (: wiregrid_api sync_subscriptions ,instance ,session ,topics)))

(defmacro defsync-presence-watches (name instance session users)
  `(defun ,name ()
     (: wiregrid_api sync_presence_watches ,instance ,session ,users)))

(defmacro defsync-rooms (name instance session rooms)
  `(defun ,name ()
     (: wiregrid_api sync_rooms ,instance ,session ,rooms)))

(defmacro defsync-topology (name instance session topology)
  `(defun ,name ()
     (: wiregrid_api sync_topology ,instance ,session ,topology)))

;; Macro-time direct routers. `routes` is a literal list of two-element lists:
;;
;;   (((tuple 'channel #"general") (fun handle-general 2))
;;    ((tuple 'channel #"alerts")  (fun handle-alert 2)))
;;
;; The generated handler is one BEAM `case` over Envelope.topic. No route map is
;; allocated or looked up on the hot path. Handlers still return ordinary
;; Wiregrid consumer results; ACK remains owned by wiregrid_worker.
(defmacro defcompiled-router (name routes default-handler)
  (let ((clauses (compile-route-clauses routes)))
    `(defun ,name (event envelope)
       (case (: maps get 'topic envelope 'undefined)
         ,@clauses
         (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))))

(defmacro defcompiled-router-worker (starter handler instance routes default-handler batch-size)
  ;; Expand the route clauses here rather than emitting another macro call.
  ;; That keeps expansion independent of caller import order and guarantees the
  ;; generated worker contains only ordinary functions after this pass.
  (let ((clauses (compile-route-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-router-worker (starter handler instance routes default-handler batch-size)
  (let ((clauses (compile-route-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

;; Compile a fixed side-effect pipeline into nested cases. This is deliberately
;; the event-preserving variant: each stage returns ok/drop/{error,Reason}. It
;; avoids per-delivery traversal of a stage list and is well suited to logging,
;; validation, metrics and application-side policy checks before ACK.
(defmacro defcompiled-effects (name stages)
  (let ((body (compile-effects-body stages)))
    `(defun ,name (event envelope) ,body)))

(defmacro defcompiled-effects-worker (starter handler instance stages batch-size)
  ;; As with the compiled router worker, expand the fixed pipeline directly so
  ;; generated modules do not depend on recursive macro expansion semantics.
  (let ((body (compile-effects-body stages)))
    `(progn
       (defun ,handler (event envelope) ,body)
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-effects-worker (starter handler instance stages batch-size)
  (let ((body (compile-effects-body stages)))
    `(progn
       (defun ,handler (event envelope) ,body)
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))


;; Compile delivery-class selection into one direct case. This avoids building a
;; selector closure or handler map on the application hot path.
(defmacro defcompiled-classifier (name durable-handler ephemeral-handler)
  `(defun ,name (event envelope)
     (case (: maps get 'class envelope 'undefined)
       ('durable (funcall ,durable-handler event envelope))
       ('ephemeral (funcall ,ephemeral-handler event envelope))
       (other (tuple 'error (tuple 'invalid_delivery_class other))))))

(defmacro defcompiled-class-worker (starter handler instance durable-handler ephemeral-handler batch-size)
  `(progn
     (defun ,handler (event envelope)
       (case (: maps get 'class envelope 'undefined)
         ('durable (funcall ,durable-handler event envelope))
         ('ephemeral (funcall ,ephemeral-handler event envelope))
         (other (tuple 'error (tuple 'invalid_delivery_class other)))))
     (defun ,starter ()
       (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size))))

(defmacro defstrict-compiled-class-worker (starter handler instance durable-handler ephemeral-handler batch-size)
  `(progn
     (defun ,handler (event envelope)
       (case (: maps get 'class envelope 'undefined)
         ('durable (funcall ,durable-handler event envelope))
         ('ephemeral (funcall ,ephemeral-handler event envelope))
         (other (tuple 'error (tuple 'invalid_delivery_class other)))))
     (defun ,starter ()
       (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash))))

;; Compile request/reply correlation selection. Context extraction stays safe
;; for ordinary non-correlated deliveries and falls back explicitly.
(defmacro defcompiled-correlation (name request-handler reply-handler default-handler)
  `(defun ,name (event envelope)
     (let ((context (: maps get 'context envelope #M())))
       (case (wiregrid_selector:context-kind context)
         ('request (funcall ,request-handler event envelope))
         ('reply (funcall ,reply-handler event envelope))
         (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))))

(defmacro defcompiled-correlation-worker (starter handler instance request-handler reply-handler default-handler batch-size)
  `(progn
     (defun ,handler (event envelope)
       (let ((context (: maps get 'context envelope #M())))
         (case (wiregrid_selector:context-kind context)
           ('request (funcall ,request-handler event envelope))
           ('reply (funcall ,reply-handler event envelope))
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope)))))
     (defun ,starter ()
       (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size))))

(defmacro defstrict-compiled-correlation-worker (starter handler instance request-handler reply-handler default-handler batch-size)
  `(progn
     (defun ,handler (event envelope)
       (let ((context (: maps get 'context envelope #M())))
         (case (wiregrid_selector:context-kind context)
           ('request (funcall ,request-handler event envelope))
           ('reply (funcall ,reply-handler event envelope))
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope)))))
     (defun ,starter ()
       (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash))))

;; Compile routing by one application event-map key. Routes use the same literal
;; `((value handler) ...)` shape as topic routers. Non-map events safely take the
;; default path instead of raising `badmap`. This is useful for fixed chat
;; protocol discriminators such as `type`, `op` or `kind`.
(defmacro defcompiled-event-router (name key routes default-handler)
  (let ((clauses (compile-event-route-clauses routes)))
    `(defun ,name (event envelope)
       (case (is_map event)
         ('true
           (case (: maps get ,key event 'undefined)
             ,@clauses
             (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
         ('false (wiregrid_selector:dispatch-default ,default-handler event envelope))))))

(defmacro defcompiled-event-router-worker (starter handler instance key routes default-handler batch-size)
  (let ((clauses (compile-event-route-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (is_map event)
           ('true
             (case (: maps get ,key event 'undefined)
               ,@clauses
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           ('false (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-event-router-worker (starter handler instance key routes default-handler batch-size)
  (let ((clauses (compile-event-route-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (is_map event)
           ('true
             (case (: maps get ,key event 'undefined)
               ,@clauses
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           ('false (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))


;; Fused topic routing + fixed effects. This is the macro-heavy hot path for
;; application protocols whose route table and pre-handler checks are static.
;; Each generated clause executes the fixed effect chain directly and then the
;; route handler; no route map or stage list is allocated/traversed per event.
(defmacro defcompiled-router-effects (name routes default-handler stages)
  (let ((clauses (compile-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(defun ,name (event envelope)
       (case (: maps get 'topic envelope 'undefined)
         ,@clauses
         (_ ,default-body)))))

(defmacro defcompiled-router-effects-worker
  (starter handler instance routes default-handler stages batch-size)
  (let ((clauses (compile-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-body)))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-router-effects-worker
  (starter handler instance routes default-handler stages batch-size)
  (let ((clauses (compile-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-body)))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

;; Fused application-event routing + fixed effects. This specializes a common
;; chat protocol shape such as #{op => message_create}. The event-map test, key
;; lookup, effects and handler selection compile into one direct function.
(defmacro defcompiled-event-router-effects (name key routes default-handler stages)
  (let ((clauses (compile-event-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(defun ,name (event envelope)
       (case (is_map event)
         ('true
           (case (: maps get ,key event 'undefined)
             ,@clauses
             (_ ,default-body)))
         ('false ,default-body)))))

(defmacro defcompiled-event-router-effects-worker
  (starter handler instance key routes default-handler stages batch-size)
  (let ((clauses (compile-event-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(progn
       (defun ,handler (event envelope)
         (case (is_map event)
           ('true
             (case (: maps get ,key event 'undefined)
               ,@clauses
               (_ ,default-body)))
           ('false ,default-body)))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-event-router-effects-worker
  (starter handler instance key routes default-handler stages batch-size)
  (let ((clauses (compile-event-route-effect-clauses routes stages))
        (default-body
          (compile-effects-terminal
            stages
            `(wiregrid_selector:dispatch-default ,default-handler event envelope))))
    `(progn
       (defun ,handler (event envelope)
         (case (is_map event)
           ('true
             (case (: maps get ,key event 'undefined)
               ,@clauses
               (_ ,default-body)))
           ('false ,default-body)))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

;; A two-dimensional compile-time router: delivery class first, exact topic
;; second. This is useful when durable and ephemeral traffic intentionally take
;; different protocol handlers and avoids constructing selector maps/closures.
(defmacro defcompiled-delivery-matrix
  (name durable-routes ephemeral-routes default-handler)
  (let ((durable (compile-route-clauses durable-routes))
        (ephemeral (compile-route-clauses ephemeral-routes)))
    `(defun ,name (event envelope)
       (case (: maps get 'class envelope 'undefined)
         ('durable
           (case (: maps get 'topic envelope 'undefined)
             ,@durable
             (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
         ('ephemeral
           (case (: maps get 'topic envelope 'undefined)
             ,@ephemeral
             (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
         (other (tuple 'error (tuple 'invalid_delivery_class other)))))))

(defmacro defcompiled-delivery-matrix-worker
  (starter handler instance durable-routes ephemeral-routes default-handler batch-size)
  (let ((durable (compile-route-clauses durable-routes))
        (ephemeral (compile-route-clauses ephemeral-routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'class envelope 'undefined)
           ('durable
             (case (: maps get 'topic envelope 'undefined)
               ,@durable
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           ('ephemeral
             (case (: maps get 'topic envelope 'undefined)
               ,@ephemeral
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           (other (tuple 'error (tuple 'invalid_delivery_class other)))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-delivery-matrix-worker
  (starter handler instance durable-routes ephemeral-routes default-handler batch-size)
  (let ((durable (compile-route-clauses durable-routes))
        (ephemeral (compile-route-clauses ephemeral-routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'class envelope 'undefined)
           ('durable
             (case (: maps get 'topic envelope 'undefined)
               ,@durable
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           ('ephemeral
             (case (: maps get 'topic envelope 'undefined)
               ,@ephemeral
               (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
           (other (tuple 'error (tuple 'invalid_delivery_class other)))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

;; Macro-expansion helpers. Invalid literal specifications fail compilation
;; instead of creating a runtime router with surprising behavior.
(defun compile-route-clauses (routes)
  (compile-route-clauses routes ()))

(defun compile-route-clauses (routes seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons handler ()))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_route topic)))
            ('false
              (cons `(,topic (funcall ,handler event envelope))
                    (compile-route-clauses rest (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_route route)))))))

(defun compile-event-route-clauses (routes)
  (compile-event-route-clauses routes ()))

(defun compile-event-route-clauses (routes seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons value (cons handler ()))
          (case (: lists member value seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_event_route value)))
            ('false
              (cons `(,value (funcall ,handler event envelope))
                    (compile-event-route-clauses rest (cons value seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_event_route route)))))))

(defun compile-effects-body (stages)
  (compile-effects-terminal stages `'ok))

(defun compile-effects-terminal (stages terminal)
  (case stages
    (() terminal)
    ((cons stage rest)
      (let ((next (compile-effects-terminal rest terminal)))
        `(case (funcall ,stage event envelope)
           ('ok ,next)
           ('drop 'drop)
           ((tuple 'error reason) (tuple 'error reason))
           (other (tuple 'error (tuple 'invalid_stage_result other))))))))

(defun compile-route-effect-clauses (routes stages)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons handler ()))
          (let ((body (compile-effects-terminal stages `(funcall ,handler event envelope))))
            (cons `(,topic ,body)
                  (compile-route-effect-clauses rest stages))))
        (_ (: erlang error (tuple 'invalid_wiregrid_route route)))))))

(defun compile-event-route-effect-clauses (routes stages)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons value (cons handler ()))
          (let ((body (compile-effects-terminal stages `(funcall ,handler event envelope))))
            (cons `(,value ,body)
                  (compile-event-route-effect-clauses rest stages))))
        (_ (: erlang error (tuple 'invalid_wiregrid_event_route route)))))))

;; Fused topic + delivery-class routing. Each literal route is:
;;
;;   (Topic DurableHandler EphemeralHandler)
;;
;; The generated handler performs one topic lookup and one class lookup, then
;; calls the fixed function directly. This is useful for chat workloads where
;; durable messages and ephemeral typing/presence events intentionally share a
;; subscription but take different application paths. No route maps or handler
;; closures are rebuilt per delivery.
(defmacro defcompiled-topic-classifier (name routes default-handler)
  (let ((clauses (compile-topic-class-clauses routes default-handler)))
    `(defun ,name (event envelope)
       (case (: maps get 'topic envelope 'undefined)
         ,@clauses
         (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))))

(defmacro defcompiled-topic-class-worker (starter handler instance routes default-handler batch-size)
  (let ((clauses (compile-topic-class-clauses routes default-handler)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-topic-class-worker (starter handler instance routes default-handler batch-size)
  (let ((clauses (compile-topic-class-clauses routes default-handler)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

;; Fused topic + request/reply routing. Each route is:
;;
;;   (Topic RequestHandler ReplyHandler DefaultHandler)
;;
;; Correlation kind comes from the already delivered envelope context, so the
;; generated hot path performs no dynamic selector construction.
(defmacro defcompiled-topic-correlation (name routes default-handler)
  (let ((clauses (compile-topic-correlation-clauses routes)))
    `(defun ,name (event envelope)
       (case (: maps get 'topic envelope 'undefined)
         ,@clauses
         (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))))

(defmacro defcompiled-topic-correlation-worker (starter handler instance routes default-handler batch-size)
  (let ((clauses (compile-topic-correlation-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size)))))

(defmacro defstrict-compiled-topic-correlation-worker (starter handler instance routes default-handler batch-size)
  (let ((clauses (compile-topic-correlation-clauses routes)))
    `(progn
       (defun ,handler (event envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
       (defun ,starter ()
         (: wiregrid_worker start_link ,instance (fun ,handler 2) ,batch-size 'crash)))))

(defun compile-topic-class-clauses (routes default-handler)
  (compile-topic-class-clauses routes default-handler ()))

(defun compile-topic-class-clauses (routes default-handler seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons durable-handler (cons ephemeral-handler ())))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_topic_class_route topic)))
            ('false
              (cons
                `(,topic
                   (case (: maps get 'class envelope 'undefined)
                     ('durable (funcall ,durable-handler event envelope))
                     ('ephemeral (funcall ,ephemeral-handler event envelope))
                     (_ (wiregrid_selector:dispatch-default ,default-handler event envelope))))
                (compile-topic-class-clauses rest default-handler (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_topic_class_route route)))))))

(defun compile-topic-correlation-clauses (routes)
  (compile-topic-correlation-clauses routes ()))

(defun compile-topic-correlation-clauses (routes seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons request-handler (cons reply-handler (cons route-default ()))))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_topic_correlation_route topic)))
            ('false
              (cons
                `(,topic
                   (let ((context (: maps get 'context envelope #M())))
                     (case (wiregrid_selector:context-kind context)
                       ('request (funcall ,request-handler event envelope))
                       ('reply (funcall ,reply-handler event envelope))
                       (_ (wiregrid_selector:dispatch-default ,route-default event envelope)))))
                (compile-topic-correlation-clauses rest (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_topic_correlation_route route)))))))


;; -------------------------------------------------------------------------
;; Compile-time rate-limit plans
;; -------------------------------------------------------------------------
;; Fixed limiter policy/instance/bucket parameters become literals. The key is
;; still runtime data and passes the canonical bounded Wiregrid API.
(defmacro deffixed-window-limit (name instance bucket limit window-ms)
  `(defun ,name (key)
     (: wiregrid_api rate_limit ,instance ,bucket key ,limit ,window-ms)))

(defmacro deftoken-bucket-limit (name instance bucket limit window-ms burst idle-ttl-ms)
  `(defun ,name (key)
     (: wiregrid_api rate_limit ,instance ,bucket key ,limit ,window-ms
        (list (tuple 'policy 'token_bucket)
              (tuple 'burst ,burst)
              (tuple 'idle_ttl_ms ,idle-ttl-ms)))))

;; -------------------------------------------------------------------------
;; Decode-late compiled kernels
;; -------------------------------------------------------------------------
;; Kernel routes are literal pairs:
;;
;;   (Topic Action)
;;
;; Action is an ordinary LFE expression evaluated only for that matching
;; delivery. Useful actions are:
;;
;;   'ack
;;   'keep
;;   (tuple 'handle (fun my-handler 2))
;;
;; The generated selector examines only envelope metadata. Payload decode does
;; not occur until wiregrid_kernel sees a `handle` action, so fixed control/event
;; routes can ACK or retain work without paying codec cost.
(defmacro defcompiled-kernel (selector consumer instance routes default-action)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1))))))

(defmacro defcompiled-kernel-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'fifo 0)))))

(defmacro defstrict-compiled-kernel-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'fifo 0)))))

;; A tiny bounded coalescing wait can improve throughput under bursty load. It
;; is capped again by wiregrid_mailbox (0..50 ms), so this cannot become an
;; unbounded application queue hidden inside the consumer process.
(defmacro defmicrobatch-kernel-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'durable_first ,wait-ms)))))

(defmacro defstrict-microbatch-kernel-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'durable_first ,wait-ms)))))

(defmacro defkernel-child-spec
  (name id instance consumer batch-size failure-policy mode wait-ms)
  `(defun ,name ()
     (: wiregrid_batch_worker child_spec ,id ,instance ,consumer ,batch-size
        ,failure-policy ,mode ,wait-ms)))

(defun compile-kernel-clauses (routes)
  (compile-kernel-clauses routes ()))

(defun compile-kernel-clauses (routes seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons action ()))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_kernel_route topic)))
            ('false
              (cons `(,topic ,action)
                    (compile-kernel-clauses rest (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_kernel_route route)))))))


;; -------------------------------------------------------------------------
;; Fused decode-late kernel matrices
;; -------------------------------------------------------------------------
;; These macros keep classification in generated BEAM pattern matching and
;; defer payload decoding until wiregrid_kernel receives a {handle, Handler}
;; action.  They are intentionally application-edge accelerators: all ACK,
;; decode, authorization and reservation ownership remains in the canonical
;; Wiregrid runtime/ABI.
;;
;; A class-matrix route is:
;;
;;   (Topic DurableAction EphemeralAction)
;;
;; This is useful when durable messages and typing/presence/cursor traffic share
;; the same topic but intentionally take different hot paths.
(defmacro defcompiled-kernel-matrix (selector consumer instance routes default-action)
  (let ((clauses (compile-kernel-matrix-clauses routes default-action)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1))))))

(defmacro defcompiled-kernel-matrix-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-matrix-clauses routes default-action)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'fifo 0)))))

(defmacro defstrict-compiled-kernel-matrix-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-matrix-clauses routes default-action)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'fifo 0)))))

(defmacro defmicrobatch-kernel-matrix-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-matrix-clauses routes default-action)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'durable_first ,wait-ms)))))

(defmacro defstrict-microbatch-kernel-matrix-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-matrix-clauses routes default-action)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'durable_first ,wait-ms)))))

;; A correlation route is:
;;
;;   (Topic RequestAction ReplyAction DefaultAction)
;;
;; Request/reply kind already lives in envelope.context, so generated selectors
;; can route correlated traffic without decoding the application event body.
(defmacro defcompiled-kernel-correlation (selector consumer instance routes default-action)
  (let ((clauses (compile-kernel-correlation-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1))))))

(defmacro defcompiled-kernel-correlation-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-correlation-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'fifo 0)))))

(defmacro defstrict-compiled-kernel-correlation-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-correlation-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'fifo 0)))))

(defmacro defmicrobatch-kernel-correlation-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-correlation-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'durable_first ,wait-ms)))))

(defmacro defstrict-microbatch-kernel-correlation-worker
  (starter selector consumer instance routes default-action batch-size wait-ms)
  (let ((clauses (compile-kernel-correlation-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'durable_first ,wait-ms)))))

(defun compile-kernel-matrix-clauses (routes default-action)
  (compile-kernel-matrix-clauses routes default-action ()))

(defun compile-kernel-matrix-clauses (routes default-action seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons durable-action (cons ephemeral-action ())))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_kernel_matrix_route topic)))
            ('false
              (cons
                `(,topic
                   (case (: maps get 'class envelope 'undefined)
                     ('durable ,durable-action)
                     ('ephemeral ,ephemeral-action)
                     (_ ,default-action)))
                (compile-kernel-matrix-clauses rest default-action (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_kernel_matrix_route route)))))))

(defun compile-kernel-correlation-clauses (routes)
  (compile-kernel-correlation-clauses routes ()))

(defun compile-kernel-correlation-clauses (routes seen)
  (case routes
    (() ())
    ((cons route rest)
      (case route
        ((cons topic (cons request-action (cons reply-action (cons route-default ()))))
          (case (: lists member topic seen)
            ('true (: erlang error (tuple 'duplicate_wiregrid_kernel_correlation_route topic)))
            ('false
              (cons
                `(,topic
                   (case (wiregrid_selector:context-kind
                           (: maps get 'context envelope #M()))
                     ('request ,request-action)
                     ('reply ,reply-action)
                     (_ ,route-default)))
                (compile-kernel-correlation-clauses rest (cons topic seen))))))
        (_ (: erlang error (tuple 'invalid_wiregrid_kernel_correlation_route route)))))))


;; Ordered decode-late kernel: identical selector DSL to defcompiled-kernel,
;; but stops on the first decode/handler/selector failure and ACKs only the
;; successful prefix. This is the safe generated form for per-session state
;; machines and projections that require strict event order.
(defmacro defcompiled-ordered-kernel (selector consumer instance routes default-action)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume-ordered ,instance envelopes (fun ,selector 1))))))

(defmacro defcompiled-ordered-kernel-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume-ordered ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'continue 'fifo 0)))))

(defmacro defstrict-compiled-ordered-kernel-worker
  (starter selector consumer instance routes default-action batch-size)
  (let ((clauses (compile-kernel-clauses routes)))
    `(progn
       (defun ,selector (envelope)
         (case (: maps get 'topic envelope 'undefined)
           ,@clauses
           (_ ,default-action)))
       (defun ,consumer (envelopes)
         (: wiregrid_kernel consume-ordered ,instance envelopes (fun ,selector 1)))
       (defun ,starter ()
         (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
            ,batch-size 'crash 'fifo 0)))))


;; -------------------------------------------------------------------------
;; Compiled authorization policies
;; -------------------------------------------------------------------------
;; `defcompiled-authorizer` generates the Authorizer.authorize/4 callback that
;; Wiregrid expects. Rules are evaluated in source order and compile to ordinary
;; BEAM pattern-match clauses over the complete authorization tuple. Supported
;; rule shapes are:
;;
;;   (Action Decision)
;;   (Action ResourcePattern Decision)
;;   (Action ResourcePattern ContextPattern Decision)
;;   (Action SessionPattern ResourcePattern ContextPattern Decision)
;;
;; Decision expressions execute with `session`, `resource` and `context`
;; lexically available. The richer forms let a policy specialize tenant/session
;; metadata and validated operation context without building maps of handlers or
;; walking a runtime rule list. More-specific rules should appear first.
(defmacro defcompiled-authorizer (rules default-decision)
  (let ((clauses (compile-authorizer-clauses rules)))
    `(defun authorize (action session resource context)
       (case (tuple action session resource context)
         ,@clauses
         (_ ,default-decision)))))

(defun compile-authorizer-clauses (rules)
  (case rules
    (() ())
    ((cons rule rest)
      (case rule
        ((cons action (cons decision ()))
          (cons `((tuple ,action _ _ _) ,decision)
                (compile-authorizer-clauses rest)))
        ((cons action (cons resource-pattern (cons decision ())))
          (cons `((tuple ,action _ ,resource-pattern _) ,decision)
                (compile-authorizer-clauses rest)))
        ((cons action (cons resource-pattern (cons context-pattern (cons decision ()))))
          (cons `((tuple ,action _ ,resource-pattern ,context-pattern) ,decision)
                (compile-authorizer-clauses rest)))
        ((cons action (cons session-pattern
                      (cons resource-pattern (cons context-pattern (cons decision ())))))
          (cons `((tuple ,action ,session-pattern ,resource-pattern ,context-pattern) ,decision)
                (compile-authorizer-clauses rest)))
        (_ (: erlang error (tuple 'invalid_wiregrid_authorizer_rule rule)))))))

;; -------------------------------------------------------------------------
;; Commit-before-ACK projections
;; -------------------------------------------------------------------------
;; A generated projection consumer delegates to wiregrid_projection, which
;; decodes each bounded delivery once, folds state in memory, calls the supplied
;; commit function exactly once for the successful batch, and ACKs only after
;; commit succeeds. This is useful for projections/materialized views where
;; acknowledging before durable state commit would create a correctness hole.
(defmacro defprojection-consumer (name instance reducer commit initial-state)
  `(defun ,name (envelopes)
     (: wiregrid_projection consume ,instance envelopes ,initial-state
        ,reducer ,commit)))

(defmacro defstrict-projection-consumer (name instance reducer commit initial-state)
  `(defun ,name (envelopes)
     (case (: wiregrid_projection consume ,instance envelopes ,initial-state
              ,reducer ,commit)
       ((tuple 'ok result) (tuple 'ok result))
       ((tuple 'error reason) (: erlang error (tuple 'wiregrid_projection_failed reason))))))


;; -------------------------------------------------------------------------
;; Compile-time custom transport command routers
;; -------------------------------------------------------------------------
;; Wiregrid.Transport.Command handles all built-in operations first. Only an
;; unknown application command reaches this generated function, with a sanitized
;; context map. Rules are `(CommandPattern ResultExpression)` and compile to
;; ordinary BEAM case clauses; `context` is lexically available to results.
(defmacro defcompiled-command-handler (rules default-result)
  (let ((clauses (compile-command-handler-clauses rules)))
    `(defun handle_command (command context)
       (case command
         ,@clauses
         (_ ,default-result)))))

(defmacro defnamed-command-handler (name rules default-result)
  (let ((clauses (compile-command-handler-clauses rules)))
    `(defun ,name (command context)
       (case command
         ,@clauses
         (_ ,default-result)))))

(defun compile-command-handler-clauses (rules)
  (case rules
    (() ())
    ((cons rule rest)
      (case rule
        ((cons pattern (cons result ()))
          (cons `(,pattern ,result)
                (compile-command-handler-clauses rest)))
        (_ (: erlang error (tuple 'invalid_wiregrid_command_handler_rule rule)))))))

;; -------------------------------------------------------------------------
;; Compile-time producer dispatch policies
;; -------------------------------------------------------------------------
;; Fixed event routing can live entirely in generated BEAM clauses instead of a
;; runtime map/registry. Rules are `(EventPattern Targets Options)` and are
;; evaluated in source order. Targets/options are still passed through the
;; canonical bounded dispatch API, so this is specialization rather than a
;; security bypass.
(defmacro defcompiled-dispatch-policy (name instance rules default-targets default-opts)
  (let ((clauses (compile-dispatch-policy-clauses rules instance)))
    `(defun ,name (event)
       (case event
         ,@clauses
         (_ (: wiregrid_api dispatch ,instance ,default-targets event ,default-opts))))))

(defun compile-dispatch-policy-clauses (rules instance)
  (case rules
    (() ())
    ((cons rule rest)
      (case rule
        ((cons pattern (cons targets (cons opts ())))
          (cons `(,pattern (: wiregrid_api dispatch ,instance ,targets event ,opts))
                (compile-dispatch-policy-clauses rest instance)))
        (_ (: erlang error (tuple 'invalid_wiregrid_dispatch_policy_rule rule)))))))

;; -------------------------------------------------------------------------
;; Bounded ordered-lane consumers
;; -------------------------------------------------------------------------
;; Lanes provide application-side parallelism for workloads that require
;; ordering per key while permitting independent keys to execute concurrently.
;; `wiregrid_lane` partitions one already-bounded batch and creates at most the
;; configured lane count; decoding, ACKs and pressure accounting remain owned by
;; canonical Wiregrid operations.
(defmacro deflane-consumer (name instance keyfun handler lane-count timeout-ms)
  `(defun ,name (envelopes)
     (: wiregrid_lane consume ,instance envelopes ,keyfun ,handler
        ,lane-count ,timeout-ms)))

(defmacro deflane-worker
  (starter consumer instance keyfun handler lane-count timeout-ms batch-size wait-ms)
  `(progn
     (defun ,consumer (envelopes)
       (: wiregrid_lane consume ,instance envelopes ,keyfun ,handler
          ,lane-count ,timeout-ms))
     (defun ,starter ()
       (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
          ,batch-size 'continue 'fifo ,wait-ms))))

(defmacro defstrict-lane-worker
  (starter consumer instance keyfun handler lane-count timeout-ms batch-size wait-ms)
  `(progn
     (defun ,consumer (envelopes)
       (: wiregrid_lane consume ,instance envelopes ,keyfun ,handler
          ,lane-count ,timeout-ms))
     (defun ,starter ()
       (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
          ,batch-size 'crash 'fifo ,wait-ms))))

(defmacro defsession-lane-worker
  (starter consumer instance handler lane-count timeout-ms batch-size wait-ms)
  `(deflane-worker ,starter ,consumer ,instance
     (fun wiregrid_lane key-session 1) ,handler ,lane-count ,timeout-ms
     ,batch-size ,wait-ms))

(defmacro deftopic-lane-worker
  (starter consumer instance handler lane-count timeout-ms batch-size wait-ms)
  `(deflane-worker ,starter ,consumer ,instance
     (fun wiregrid_lane key-topic 1) ,handler ,lane-count ,timeout-ms
     ,batch-size ,wait-ms))

(defmacro defrequest-lane-worker
  (starter consumer instance handler lane-count timeout-ms batch-size wait-ms)
  `(deflane-worker ,starter ,consumer ,instance
     (fun wiregrid_lane key-request 1) ,handler ,lane-count ,timeout-ms
     ,batch-size ,wait-ms))

;; -------------------------------------------------------------------------
;; Bounded ephemeral coalescing
;; -------------------------------------------------------------------------
;; Coalescing runs before decode and affects only `ephemeral` deliveries.
;; Durable work is never collapsed. Superseded ephemeral reservations are ACKed
;; by wiregrid_coalesce and the newest selected envelopes continue through the
;; normal decode/handler/ACK pipeline.
;; -------------------------------------------------------------------------
;; Compile-time durable replay bindings
;; -------------------------------------------------------------------------
;; A replayer fixes instance/stream at compile time while retaining the
;; canonical Wiregrid replay implementation and its opaque cursor semantics.
;; Generated functions accept a live session and optionally canonical replay
;; options such as cursor/limit/class/topic.
(defmacro defreplayer (name instance stream)
  `(progn
     (defun ,name (session)
       (: wiregrid_fast replay-session ,instance session ,stream))
     (defun ,name (session opts)
       (: wiregrid_fast replay-session ,instance session ,stream opts))))

(defmacro defcoalescing-consumer (name instance keyfun handler)
  `(defun ,name (envelopes)
     (: wiregrid_coalesce consume-latest ,instance envelopes ,keyfun ,handler)))

(defmacro defcoalescing-worker
  (starter consumer instance keyfun handler batch-size wait-ms)
  `(progn
     (defun ,consumer (envelopes)
       (: wiregrid_coalesce consume-latest ,instance envelopes ,keyfun ,handler))
     (defun ,starter ()
       (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
          ,batch-size 'continue 'fifo ,wait-ms))))

(defmacro deftopic-coalescing-worker
  (starter consumer instance handler batch-size wait-ms)
  `(defcoalescing-worker ,starter ,consumer ,instance
     (fun wiregrid_coalesce key-topic 1) ,handler ,batch-size ,wait-ms))

(defmacro defsession-topic-coalescing-worker
  (starter consumer instance handler batch-size wait-ms)
  `(defcoalescing-worker ,starter ,consumer ,instance
     (fun wiregrid_coalesce key-session-topic 1) ,handler ,batch-size ,wait-ms))



;; -------------------------------------------------------------------------
;; Fused ephemeral coalescing + ordered lane execution
;; -------------------------------------------------------------------------
;; Generated consumers collapse only superseded ephemeral work before decode,
;; then process survivors through bounded ordered lanes. This is useful for
;; realtime UI/activity bursts where durable events must remain exact but
;; transient updates should not waste codec/handler CPU.
(defmacro defcoalesced-lane-consumer
  (name instance coalesce-keyfun lane-keyfun handler lane-count timeout-ms)
  `(defun ,name (envelopes)
     (: wiregrid_flow consume-coalesced-lanes ,instance envelopes
        ,coalesce-keyfun ,lane-keyfun ,handler ,lane-count ,timeout-ms)))

(defmacro defcoalesced-lane-worker
  (starter consumer instance coalesce-keyfun lane-keyfun handler
           lane-count timeout-ms batch-size wait-ms)
  `(progn
     (defun ,consumer (envelopes)
       (: wiregrid_flow consume-coalesced-lanes ,instance envelopes
          ,coalesce-keyfun ,lane-keyfun ,handler ,lane-count ,timeout-ms))
     (defun ,starter ()
       (: wiregrid_batch_worker start_link ,instance (fun ,consumer 1)
          ,batch-size 'continue 'fifo ,wait-ms))))

(defmacro defsession-coalesced-lane-worker
  (starter consumer instance handler lane-count timeout-ms batch-size wait-ms)
  `(defcoalesced-lane-worker ,starter ,consumer ,instance
     (fun wiregrid_coalesce key-session-topic 1)
     (fun wiregrid_lane key-session 1)
     ,handler ,lane-count ,timeout-ms ,batch-size ,wait-ms))

(defmacro defrequest-coalesced-lane-worker
  (starter consumer instance handler lane-count timeout-ms batch-size wait-ms)
  `(defcoalesced-lane-worker ,starter ,consumer ,instance
     (fun wiregrid_coalesce key-request 1)
     (fun wiregrid_lane key-request 1)
     ,handler ,lane-count ,timeout-ms ,batch-size ,wait-ms))
