;; Adaptive off-heap burst worker for Wiregrid's LFE hot path.
;;
;; Unlike a fixed-delay micro-batcher, this worker inspects only its own mailbox
;; length after the first delivery arrives. It never calls process_info on a
;; recipient/session process and never scans an unbounded mailbox. Under light
;; traffic it handles immediately; under a local burst it uses a tiny bounded
;; collect delay to amortize decode/ACK/handler overhead.
(defmodule wiregrid_adaptive_worker
  (export all))

(defun child_spec (id instance batch-handler batch-size)
  (child_spec id instance batch-handler batch-size 'continue 'fifo 2))
(defun child_spec (id instance batch-handler batch-size failure-policy mode max-wait-ms)
  (case (valid-options instance batch-handler batch-size failure-policy mode max-wait-ms)
    ('ok
      #M(id id
         start (tuple 'wiregrid_adaptive_worker 'start_link
                      (list instance batch-handler batch-size failure-policy mode max-wait-ms))
         restart 'permanent shutdown 5000 type 'worker
         modules (list 'wiregrid_adaptive_worker)))
    (error error)))

(defun start_link (instance batch-handler batch-size failure-policy mode max-wait-ms)
  (case (valid-options instance batch-handler batch-size failure-policy mode max-wait-ms)
    ('ok
      (let ((pid (: erlang spawn_link
                     (lambda ()
                       (init instance batch-handler batch-size failure-policy mode max-wait-ms)))))
        (tuple 'ok pid)))
    (error error)))

(defun stats (pid) (call pid 'stats 5000))
(defun stop (pid) (call pid 'stop 5000))

(defun init (instance batch-handler batch-size failure-policy mode max-wait-ms)
  (: erlang process_flag 'message_queue_data 'off_heap)
  (loop instance batch-handler batch-size failure-policy mode max-wait-ms
        #M(batches 0 envelopes 0 handled 0 failed 0 waits 0 max_wait_ms max-wait-ms)))

(defun loop (instance batch-handler batch-size failure-policy mode max-wait-ms stats)
  (receive
    ((tuple '$wiregrid envelope)
      (let* ((wait-ms (adaptive-wait batch-size max-wait-ms))
             (batch (wiregrid_mailbox:collect-wait envelope batch-size wait-ms))
             (ordered (wiregrid_mailbox:order batch mode)))
        (case (is_list ordered)
          ('true
            (handle-batch instance batch-handler batch-size failure-policy mode max-wait-ms
                          (case (> wait-ms 0)
                            ('true (: maps update_with 'waits (lambda (n) (+ n 1)) 1 stats))
                            ('false stats))
                          ordered))
          ('false (: erlang exit (tuple 'wiregrid_adaptive_worker_invalid_batch ordered))))))

    ((tuple 'wiregrid_adaptive_worker 'call from ref 'stats)
      (: erlang send from (tuple 'wiregrid_adaptive_worker ref (tuple 'ok stats)))
      (loop instance batch-handler batch-size failure-policy mode max-wait-ms stats))

    ((tuple 'wiregrid_adaptive_worker 'call from ref 'stop)
      (: erlang send from (tuple 'wiregrid_adaptive_worker ref 'ok))
      'ok)

    (_other
      (loop instance batch-handler batch-size failure-policy mode max-wait-ms stats))))

(defun adaptive-wait (batch-size max-wait-ms)
  ;; Querying our own queue is O(1) runtime metadata and cannot amplify fanout.
  (case (: erlang process_info (self) 'message_queue_len)
    ((tuple 'message_queue_len length)
      (cond
        ((>= length (- batch-size 1)) 0)
        ((>= length 32) 0)
        ((>= length 8) (min max-wait-ms 1))
        ((> length 0) (min max-wait-ms 1))
        ('true max-wait-ms)))
    (_ 0)))

(defun handle-batch (instance batch-handler batch-size failure-policy mode max-wait-ms stats batch)
  (let ((result (safe-call batch-handler batch)))
    (case result
      ((tuple 'ok details)
        (case (andalso (=:= failure-policy 'crash) (> (: maps get 'failed details 0) 0))
          ('true (: erlang exit (tuple 'wiregrid_adaptive_worker_failed details)))
          ('false
            (loop instance batch-handler batch-size failure-policy mode max-wait-ms
                  (merge-success stats details (: erlang length batch))))))
      ((tuple 'error details)
        (case (=:= failure-policy 'crash)
          ('true (: erlang exit (tuple 'wiregrid_adaptive_worker_failed details)))
          ('false
            (loop instance batch-handler batch-size failure-policy mode max-wait-ms
                  (merge-error stats details (: erlang length batch))))))
      (other (: erlang exit (tuple 'wiregrid_adaptive_worker_invalid_result other))))))

(defun safe-call (batch-handler batch)
  (try
    (funcall batch-handler batch)
    (catch
      ((tuple class reason _stack)
        (tuple 'error (tuple 'batch_handler_failed class reason))))))

(defun merge-success (stats details count)
  (: maps merge stats
     #M(batches (+ (: maps get 'batches stats 0) 1)
        envelopes (+ (: maps get 'envelopes stats 0) count)
        handled (+ (: maps get 'handled stats 0) (: maps get 'handled details 0))
        failed (+ (: maps get 'failed stats 0) (: maps get 'failed details 0))
        kept (+ (: maps get 'kept stats 0) (: maps get 'kept details 0))
        ack_only (+ (: maps get 'ack_only stats 0) (: maps get 'ack_only details 0)))))

(defun merge-error (stats details count)
  (: maps merge stats
     #M(batches (+ (: maps get 'batches stats 0) 1)
        envelopes (+ (: maps get 'envelopes stats 0) count)
        failed (+ (: maps get 'failed stats 0) count)
        last_error details)))

(defun valid-options (instance batch-handler batch-size failure-policy mode max-wait-ms)
  (cond
    ((not (is_function batch-handler 1)) (tuple 'error 'invalid_batch_handler))
    ((not (orelse (=:= failure-policy 'continue) (=:= failure-policy 'crash)))
      (tuple 'error 'invalid_failure_policy))
    ((not (orelse (=:= mode 'fifo) (=:= mode 'durable_first)))
      (tuple 'error 'invalid_mode))
    ((not (andalso (is_integer max-wait-ms) (>= max-wait-ms 0) (=< max-wait-ms 8)))
      (tuple 'error 'invalid_adaptive_wait))
    ('true (wiregrid_fast:validate-batch-size instance batch-size))))

(defun call (pid operation timeout)
  (case (andalso (is_pid pid) (is_integer timeout) (> timeout 0))
    ('true
      (let ((ref (: erlang make_ref)))
        (: erlang send pid (tuple 'wiregrid_adaptive_worker 'call (self) ref operation))
        (receive
          ((tuple 'wiregrid_adaptive_worker ref reply) reply)
          (after timeout (tuple 'error 'timeout)))))
    ('false (tuple 'error 'invalid_call))))

(defun min (a b)
  (case (< a b) ('true a) ('false b)))
