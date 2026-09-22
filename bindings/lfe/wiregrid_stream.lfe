;; Tail-recursive batch orchestration for high-throughput LFE applications.
;; This stays outside the core runtime so Wiregrid itself has no LFE runtime
;; dependency, while LFE callers get efficient chunking and explicit partial
;; result accounting over the stable Erlang ABI.
(defmodule wiregrid_stream
  (export all))

(defun publish-chunks (instance topic events chunk-size)
  (case (valid-chunk-size chunk-size)
    ('true (publish-chunks-loop instance topic events chunk-size 0 0 0))
    ('false (tuple 'error 'invalid_chunk_size))))

(defun publish-chunks (instance topic events chunk-size opts)
  (case (valid-chunk-size chunk-size)
    ('true (publish-chunks-loop instance topic events chunk-size opts 0 0 0))
    ('false (tuple 'error 'invalid_chunk_size))))

(defun send-session-chunks (instance sessions event chunk-size)
  (case (valid-chunk-size chunk-size)
    ('true (send-session-chunks-loop instance sessions event chunk-size 0 0))
    ('false (tuple 'error 'invalid_chunk_size))))

(defun send-user-chunks (instance users event chunk-size)
  (case (valid-chunk-size chunk-size)
    ('true (send-user-chunks-loop instance users event chunk-size 0 0))
    ('false (tuple 'error 'invalid_chunk_size))))

(defun publish-chunks-loop (instance topic events chunk-size chunks completed failed)
  (case events
    (() (tuple 'ok (tuple chunks completed failed)))
    (_
      (let (((tuple chunk rest) (take-chunk events chunk-size)))
        (case (wiregrid_api:publish_batch instance topic chunk)
          ((tuple 'ok result)
            (publish-chunks-loop instance topic rest chunk-size
                                 (+ chunks 1)
                                 (+ completed (: maps get 'completed result 0))
                                 (+ failed (: maps get 'failed result 0))))
          (error (tuple 'error (tuple chunks completed failed error))))))))

(defun publish-chunks-loop (instance topic events chunk-size opts chunks completed failed)
  (case events
    (() (tuple 'ok (tuple chunks completed failed)))
    (_
      (let (((tuple chunk rest) (take-chunk events chunk-size)))
        (case (wiregrid_api:publish_batch instance topic chunk opts)
          ((tuple 'ok result)
            (publish-chunks-loop instance topic rest chunk-size opts
                                 (+ chunks 1)
                                 (+ completed (: maps get 'completed result 0))
                                 (+ failed (: maps get 'failed result 0))))
          (error (tuple 'error (tuple chunks completed failed error))))))))

(defun send-session-chunks-loop (instance sessions event chunk-size chunks sent)
  (case sessions
    (() (tuple 'ok (tuple chunks sent)))
    (_
      (let (((tuple chunk rest) (take-chunk sessions chunk-size)))
        (case (wiregrid_api:send_sessions instance chunk event)
          ((tuple 'ok counts)
            (send-session-chunks-loop instance rest event chunk-size
                                      (+ chunks 1)
                                      (+ sent (: maps get 'sent counts 0))))
          (error (tuple 'error (tuple chunks sent error))))))))

(defun send-user-chunks-loop (instance users event chunk-size chunks sent)
  (case users
    (() (tuple 'ok (tuple chunks sent)))
    (_
      (let (((tuple chunk rest) (take-chunk users chunk-size)))
        (case (wiregrid_api:send_users instance chunk event)
          ((tuple 'ok counts)
            (send-user-chunks-loop instance rest event chunk-size
                                   (+ chunks 1)
                                   (+ sent (: maps get 'sent counts 0))))
          (error (tuple 'error (tuple chunks sent error))))))))

(defun take-chunk (items count)
  (take-chunk items count ()))

(defun take-chunk
  ((items 0 acc)
    (tuple (: lists reverse acc) items))
  ((() _count acc)
    (tuple (: lists reverse acc) ()))
  (((cons item rest) count acc)
    (take-chunk rest (- count 1) (cons item acc))))

(defun valid-chunk-size (value)
  (andalso (is_integer value) (> value 0) (=< value 4096)))

;; Lifecycle chunkers use Wiregrid's native single-control-call batch APIs.
;; They are useful when a bootstrap set is intentionally larger than one
;; instance max_batch_items value; every chunk still has explicit partial
;; progress accounting.
(defun subscribe-chunks (instance session topics chunk-size)
  (lifecycle-chunks instance session topics chunk-size 'subscribe))
(defun unsubscribe-chunks (instance session topics chunk-size)
  (lifecycle-chunks instance session topics chunk-size 'unsubscribe))
(defun watch-chunks (instance session users chunk-size)
  (lifecycle-chunks instance session users chunk-size 'watch))
(defun unwatch-chunks (instance session users chunk-size)
  (lifecycle-chunks instance session users chunk-size 'unwatch))
(defun join-room-chunks (instance session rooms chunk-size)
  (lifecycle-chunks instance session rooms chunk-size 'join))
(defun leave-room-chunks (instance session rooms chunk-size)
  (lifecycle-chunks instance session rooms chunk-size 'leave))

(defun lifecycle-chunks (instance session items chunk-size operation)
  (case (valid-chunk-size chunk-size)
    ('true (lifecycle-chunks-loop instance session items chunk-size operation 0 0 0))
    ('false (tuple 'error 'invalid_chunk_size))))

(defun lifecycle-chunks-loop
  ((_instance _session () _chunk-size _operation chunks completed failed)
    (tuple 'ok (tuple chunks completed failed)))
  ((instance session items chunk-size operation chunks completed failed)
    (let (((tuple chunk rest) (take-chunk items chunk-size)))
      (case (lifecycle-call instance session chunk operation)
        ((tuple 'ok result)
          (lifecycle-chunks-loop instance session rest chunk-size operation
                                 (+ chunks 1)
                                 (+ completed (: maps get 'completed result 0))
                                 (+ failed (: maps get 'failed result 0))))
        (error (tuple 'error (tuple chunks completed failed error)))))))

(defun lifecycle-call (instance session items operation)
  (case operation
    ('subscribe (wiregrid_api:subscribe_many instance session items))
    ('unsubscribe (wiregrid_api:unsubscribe_many instance session items))
    ('watch (wiregrid_api:watch_presence_many instance session items))
    ('unwatch (wiregrid_api:unwatch_presence_many instance session items))
    ('join (wiregrid_api:join_rooms instance items session))
    ('leave (wiregrid_api:leave_rooms instance items session))
    (_ (tuple 'error 'invalid_operation))))
