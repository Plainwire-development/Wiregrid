;; Bounded parallel lane execution for high-throughput LFE consumers.
;;
;; A caller supplies one already-bounded Wiregrid delivery batch. Envelopes are
;; partitioned by a stable key into a fixed number of lanes. Every lane executes
;; sequentially, preserving order for envelopes that hash to the same key, while
;; independent lanes can run concurrently. At most `lane-count` short-lived
;; workers exist for one invocation; no unbounded task/process fanout is allowed.
;;
;; ACK semantics remain canonical: each lane delegates to wiregrid_pipeline,
;; which ACKs only deliveries whose handler completed successfully.
(defmodule wiregrid_lane
  (export all))

(defun consume (instance envelopes keyfun handler lane-count)
  (consume instance envelopes keyfun handler lane-count 5000))

(defun consume (instance envelopes keyfun handler lane-count timeout-ms)
  (case (validate instance envelopes keyfun handler lane-count timeout-ms)
    ('ok
      (let* ((lanes (partition envelopes keyfun lane-count))
             (jobs (spawn-lanes instance lanes handler (self) ()))
             (deadline (+ (: erlang monotonic_time 'millisecond) timeout-ms)))
        (await-jobs jobs deadline 0 0 0 ())))
    (error error)))

(defun partition (envelopes keyfun lane-count)
  (partition-loop envelopes keyfun lane-count #M()))

(defun partition-loop
  ((() _keyfun _lane-count lanes)
    (ordered-lanes (: maps to_list lanes) ()))
  (((cons envelope rest) keyfun lane-count lanes)
    (let* ((key (safe-key keyfun envelope))
           (lane (: erlang phash2 key lane-count))
           (current (: maps get lane lanes ())))
      (partition-loop rest keyfun lane-count
                      (: maps put lane (cons envelope current) lanes)))))

(defun ordered-lanes
  ((() acc) (: lists reverse acc))
  (((cons (tuple lane reversed) rest) acc)
    (ordered-lanes rest (cons (tuple lane (: lists reverse reversed)) acc))))

(defun spawn-lanes
  ((_instance () _handler _parent acc) (: lists reverse acc))
  ((instance (cons (tuple lane envelopes) rest) handler parent acc)
    (let* ((token (: erlang make_ref))
           ((tuple pid monitor)
             (: erlang spawn_opt
                (lambda ()
                  (let ((result (safe-consume instance envelopes handler)))
                    (: erlang send parent (tuple 'wiregrid_lane token result))))
                (list 'monitor (tuple 'message_queue_data 'off_heap)))))
      (spawn-lanes instance rest handler parent
                   (cons (tuple lane token pid monitor (: erlang length envelopes)) acc)))))

(defun await-jobs
  ((() _deadline handled failed lanes results)
    (tuple 'ok #M(handled handled failed failed lanes lanes partial (> failed 0)
                  results (: lists reverse results))))
  (((cons job rest) deadline handled failed lanes results)
    (case (await-job job deadline)
      ((tuple 'ok lane-result)
        (let ((h (: maps get 'handled lane-result 0))
              (f (: maps get 'failed lane-result 0)))
          (await-jobs rest deadline (+ handled h) (+ failed f) (+ lanes 1)
                      (cons lane-result results))))
      ((tuple 'error lane-error)
        (let ((count (: maps get 'envelopes lane-error 1)))
          (await-jobs rest deadline handled (+ failed count) (+ lanes 1)
                      (cons lane-error results)))))))

(defun await-job
  (((tuple lane token pid monitor count) deadline)
    (let ((remaining (larger 0 (- deadline (: erlang monotonic_time 'millisecond)))))
      (receive
        ((tuple 'wiregrid_lane token result)
          (: erlang demonitor monitor (list 'flush))
          (normalize-result lane count result))
        ((tuple 'DOWN monitor 'process pid reason)
          (tuple 'error #M(lane lane envelopes count reason reason)))
        (after remaining
          (: erlang exit pid 'kill)
          (receive
            ((tuple 'DOWN monitor 'process pid _reason) 'ok)
            (after 100 'ok))
          (tuple 'error #M(lane lane envelopes count reason 'timeout)))))))

(defun normalize-result
  ((lane count (tuple 'ok details))
    (tuple 'ok (: maps merge #M(lane lane envelopes count) details)))
  ((lane count (tuple 'error details))
    (tuple 'error #M(lane lane envelopes count reason details)))
  ((lane count other)
    (tuple 'error #M(lane lane envelopes count reason (tuple 'invalid_lane_result other)))))

(defun safe-consume (instance envelopes handler)
  (try
    (wiregrid_pipeline:consume-many instance envelopes handler)
    (catch
      ((tuple class reason _stack)
        (tuple 'error (tuple 'lane_failed class reason))))))

(defun safe-key (keyfun envelope)
  (try
    (funcall keyfun envelope)
    (catch
      ((tuple _class _reason _stack)
        ;; Delivery ID is unique and bounded, giving failures a deterministic
        ;; isolated lane rather than crashing partition construction.
        (: maps get 'delivery_id envelope 'undefined)))))

(defun key-session (envelope)
  (: maps get 'session_id envelope (: maps get 'delivery_id envelope 'undefined)))
(defun key-topic (envelope)
  (: maps get 'topic envelope (: maps get 'delivery_id envelope 'undefined)))
(defun key-delivery (envelope)
  (: maps get 'delivery_id envelope 'undefined))
(defun key-request (envelope)
  (let ((context (: maps get 'context envelope #M())))
    (: maps get 'request_id context (: maps get 'delivery_id envelope 'undefined))))

(defun validate (instance envelopes keyfun handler lane-count timeout-ms)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (cond
        ((not (is_function keyfun 1)) (tuple 'error 'invalid_lane_key_function))
        ((not (is_function handler 2)) (tuple 'error 'invalid_lane_handler))
        ((not (andalso (is_integer lane-count) (> lane-count 0) (=< lane-count 64)))
          (tuple 'error 'invalid_lane_count))
        ((not (andalso (is_integer timeout-ms) (> timeout-ms 0) (=< timeout-ms 60000)))
          (tuple 'error 'invalid_lane_timeout))
        ('true 'ok)))
    (error error)))

(defun larger (a b)
  (case (> a b)
    ('true a)
    ('false b)))
