;; Bounded batch-owner worker for pre-decoding LFE kernels and custom batch
;; consumers. Unlike wiregrid_worker, the handler receives the whole bounded
;; envelope burst and therefore may classify metadata before decoding payloads.
(defmodule wiregrid_batch_worker
  (export all))

(defun child_spec (id instance handler batch-size)
  (child_spec id instance handler batch-size 'continue 'fifo 0))
(defun child_spec (id instance handler batch-size failure-policy mode wait-ms)
  (case (valid-options instance handler batch-size failure-policy mode wait-ms)
    ('ok
      #M(id id
         start (tuple 'wiregrid_batch_worker 'start_link
                      (list instance handler batch-size failure-policy mode wait-ms))
         restart 'permanent
         shutdown 5000
         type 'worker
         modules (list 'wiregrid_batch_worker)))
    (error error)))

(defun start_link (instance handler batch-size)
  (start_link instance handler batch-size 'continue 'fifo 0))
(defun start_link (instance handler batch-size failure-policy mode wait-ms)
  (case (valid-options instance handler batch-size failure-policy mode wait-ms)
    ('ok
      (let ((pid (: erlang spawn_link
                     (lambda () (init instance handler batch-size failure-policy mode wait-ms)))))
        (tuple 'ok pid)))
    (error error)))

(defun start (instance handler batch-size failure-policy mode wait-ms)
  (case (valid-options instance handler batch-size failure-policy mode wait-ms)
    ('ok
      (let ((pid (: erlang spawn
                     (lambda () (init instance handler batch-size failure-policy mode wait-ms)))))
        (tuple 'ok pid)))
    (error error)))

(defun stop (pid) (request pid 'stop 5000))
(defun stats (pid) (request pid 'stats 5000))
(defun hibernate (pid)
  (case (is_pid pid)
    ('true (: erlang send pid (tuple 'wiregrid_batch_worker 'cast 'hibernate)) 'ok)
    ('false (tuple 'error 'invalid_pid))))

(defun init (instance handler batch-size failure-policy mode wait-ms)
  (: erlang process_flag 'message_queue_data 'off_heap)
  (loop instance handler batch-size failure-policy mode wait-ms
        #M(batches 0 envelopes 0 handled 0 failed 0 kept 0 ack_only 0 mode mode
           collect_wait_ms wait-ms)))

(defun loop (instance handler batch-size failure-policy mode wait-ms stats)
  (receive
    ((tuple '$wiregrid envelope)
      (let* ((batch (wiregrid_mailbox:collect-wait envelope batch-size wait-ms))
             (ordered (wiregrid_mailbox:order batch mode)))
        (case (is_list ordered)
          ('true (handle-batch instance handler batch-size failure-policy mode wait-ms stats ordered))
          ('false (: erlang exit (tuple 'wiregrid_batch_worker_invalid_batch ordered))))))

    ((tuple 'wiregrid_batch_worker 'call from ref 'stats)
      (: erlang send from (tuple 'wiregrid_batch_worker ref (tuple 'ok stats)))
      (loop instance handler batch-size failure-policy mode wait-ms stats))

    ((tuple 'wiregrid_batch_worker 'call from ref 'stop)
      (: erlang send from (tuple 'wiregrid_batch_worker ref 'ok))
      'ok)

    ((tuple 'wiregrid_batch_worker 'cast 'hibernate)
      (: proc_lib hibernate 'wiregrid_batch_worker 'wake
         (list instance handler batch-size failure-policy mode wait-ms stats)))

    (_other
      (loop instance handler batch-size failure-policy mode wait-ms stats))))

(defun wake (instance handler batch-size failure-policy mode wait-ms stats)
  (loop instance handler batch-size failure-policy mode wait-ms stats))

(defun handle-batch (instance handler batch-size failure-policy mode wait-ms stats batch)
  (let ((result (safe-batch-handler handler batch)))
    (case result
      ((tuple 'ok details)
        (case (andalso (=:= failure-policy 'crash)
                       (> (: maps get 'failed details 0) 0))
          ('true (: erlang exit (tuple 'wiregrid_batch_worker_failed details)))
          ('false
            (loop instance handler batch-size failure-policy mode wait-ms
                  (merge-success stats details (: erlang length batch))))))
      ((tuple 'error details)
        (case (=:= failure-policy 'crash)
          ('true (: erlang exit (tuple 'wiregrid_batch_worker_failed details)))
          ('false
            (loop instance handler batch-size failure-policy mode wait-ms
                  (merge-error stats details (: erlang length batch))))))
      (other
        (: erlang exit (tuple 'wiregrid_batch_worker_invalid_result other))))))

(defun safe-batch-handler (handler batch)
  (try
    (funcall handler batch)
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

(defun valid-options (instance handler batch-size failure-policy mode wait-ms)
  (cond
    ((not (is_function handler 1)) (tuple 'error 'invalid_batch_handler))
    ((not (orelse (=:= failure-policy 'continue) (=:= failure-policy 'crash)))
      (tuple 'error 'invalid_failure_policy))
    ((not (orelse (=:= mode 'fifo) (=:= mode 'durable_first)))
      (tuple 'error 'invalid_mode))
    ('true
      (case (wiregrid_fast:validate-batch-size instance batch-size)
        ('ok (wiregrid_mailbox:valid-wait wait-ms))
        (error error)))))

(defun request (pid operation timeout)
  (case (andalso (is_pid pid) (is_integer timeout) (> timeout 0))
    ('true
      (let ((ref (: erlang make_ref)))
        (: erlang send pid (tuple 'wiregrid_batch_worker 'call (self) ref operation))
        (receive
          ((tuple 'wiregrid_batch_worker ref reply) reply)
          (after timeout (tuple 'error 'timeout)))))
    ('false (tuple 'error 'invalid_call))))
