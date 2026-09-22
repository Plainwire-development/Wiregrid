;; Bounded high-throughput Wiregrid consumer loop for LFE applications.
;;
;; This is intentionally an application-side worker, not a second Wiregrid
;; runtime. It consumes the ordinary {$wiregrid, Envelope} mailbox protocol,
;; batches only already-arrived deliveries with a zero-time selective receive,
;; invokes one caller-supplied handler, and releases reservations only after
;; successful handling via wiregrid_pipeline:consume-many/3.
(defmodule wiregrid_worker
  (export all))

;; OTP child specs make the high-throughput LFE worker a first-class supervised
;; component without introducing a second runtime. The caller supplies the id
;; explicitly so multiple workers can coexist under one supervisor.
(defun child_spec (id instance handler batch-size)
  (child_spec id instance handler batch-size 'continue 'fifo))

(defun child_spec (id instance handler batch-size failure-policy)
  (child_spec id instance handler batch-size failure-policy 'fifo))

(defun child_spec (id instance handler batch-size failure-policy mode)
  (case (valid-options handler batch-size failure-policy)
    ('ok
      (case (valid-mode mode)
        ('ok
          #M(id id
             start (tuple 'wiregrid_worker 'start_link_mode
                          (list instance handler batch-size failure-policy mode))
             restart 'permanent
             shutdown 5000
             type 'worker
             modules (list 'wiregrid_worker)))
        (error error)))
    (error error)))

(defun priority_child_spec (id instance handler batch-size)
  (child_spec id instance handler batch-size 'continue 'durable_first))

(defun priority_child_spec (id instance handler batch-size failure-policy)
  (child_spec id instance handler batch-size failure-policy 'durable_first))

(defun start_link (instance handler batch-size)
  (start_link instance handler batch-size 'continue))

(defun start_link (instance handler batch-size failure-policy)
  (start_link_mode instance handler batch-size failure-policy 'fifo))

(defun start_link_priority (instance handler batch-size)
  (start_link_priority instance handler batch-size 'continue))

(defun start_link_priority (instance handler batch-size failure-policy)
  (start_link_mode instance handler batch-size failure-policy 'durable_first))

(defun start_link_mode (instance handler batch-size failure-policy mode)
  (case (valid-options handler batch-size failure-policy)
    ('ok
      (case (wiregrid_fast:validate-batch-size instance batch-size)
        ('ok
          (case (valid-mode mode)
            ('ok
              (let ((pid (: erlang spawn_link
                             (lambda () (init instance handler batch-size failure-policy mode)))))
                (tuple 'ok pid)))
            (error error)))
        (error error)))
    (error error)))

(defun start (instance handler batch-size)
  (start instance handler batch-size 'continue))

(defun start (instance handler batch-size failure-policy)
  (start_mode instance handler batch-size failure-policy 'fifo))

(defun start_priority (instance handler batch-size)
  (start_priority instance handler batch-size 'continue))

(defun start_priority (instance handler batch-size failure-policy)
  (start_mode instance handler batch-size failure-policy 'durable_first))

(defun start_mode (instance handler batch-size failure-policy mode)
  (case (valid-options handler batch-size failure-policy)
    ('ok
      (case (wiregrid_fast:validate-batch-size instance batch-size)
        ('ok
          (case (valid-mode mode)
            ('ok
              (let ((pid (: erlang spawn
                             (lambda () (init instance handler batch-size failure-policy mode)))))
                (tuple 'ok pid)))
            (error error)))
        (error error)))
    (error error)))


;; Fixed route workers keep their route map as a literal in generated modules.
;; Routing occurs after canonical decode and before canonical grouped ACK.
(defun start_link_router (instance routes default-handler batch-size)
  (case (wiregrid_router:valid-routes routes default-handler)
    ('ok
      (start_link instance
                  (lambda (event envelope)
                    (wiregrid_router:handle-event event envelope routes default-handler))
                  batch-size))
    (error error)))

(defun start_link_router (instance routes default-handler batch-size failure-policy)
  (case (wiregrid_router:valid-routes routes default-handler)
    ('ok
      (start_link instance
                  (lambda (event envelope)
                    (wiregrid_router:handle-event event envelope routes default-handler))
                  batch-size failure-policy))
    (error error)))

;; Class-specialized workers choose the handler from the delivery envelope
;; without decoding or rebuilding routing configuration more than once.
(defun start_link_classified (instance durable-handler ephemeral-handler batch-size)
  (start_link_classified instance durable-handler ephemeral-handler batch-size 'continue))

(defun start_link_classified (instance durable-handler ephemeral-handler batch-size failure-policy)
  (case (wiregrid_selector:valid-handler-pair durable-handler ephemeral-handler)
    ('ok
      (start_link instance
                  (lambda (event envelope)
                    (case (: maps get 'class envelope 'undefined)
                      ('durable (funcall durable-handler event envelope))
                      ('ephemeral (funcall ephemeral-handler event envelope))
                      (other (tuple 'error (tuple 'invalid_delivery_class other)))))
                  batch-size failure-policy))
    (error error)))

;; Correlation-specialized workers are useful for request/reply protocols where
;; request and reply handlers are fixed for the lifetime of the owner process.
(defun start_link_correlated (instance request-handler reply-handler default-handler batch-size)
  (start_link_correlated instance request-handler reply-handler default-handler batch-size 'continue))

(defun start_link_correlated (instance request-handler reply-handler default-handler batch-size failure-policy)
  (case (wiregrid_selector:valid-correlation-handlers request-handler reply-handler default-handler)
    ('ok
      (start_link instance
                  (lambda (event envelope)
                    (let ((context (: maps get 'context envelope #M())))
                      (case (wiregrid_selector:context-kind context)
                        ('request (funcall request-handler event envelope))
                        ('reply (funcall reply-handler event envelope))
                        (_ (wiregrid_selector:dispatch-default default-handler event envelope)))))
                  batch-size failure-policy))
    (error error)))

;; Fixed stage workers avoid constructing a pipeline per delivery. `drop` is an
;; intentional successful consumption and therefore becomes `ok` for ACK.
(defun start_link_pipeline (instance stages batch-size)
  (start_link_pipeline instance stages batch-size 'continue))

(defun start_link_pipeline (instance stages batch-size failure-policy)
  (case (is_list stages)
    ('true
      (start_link instance
                  (lambda (event envelope)
                    (case (wiregrid_pipeline:run event envelope stages)
                      ('drop 'ok)
                      ((tuple 'ok value) (tuple 'ok value))
                      (error error)))
                  batch-size failure-policy))
    ('false (tuple 'error 'invalid_stages))))

(defun stop (pid)
  (request pid 'stop 5000))

(defun stats (pid)
  (request pid 'stats 5000))

(defun init (instance handler batch-size failure-policy mode)
  (: erlang process_flag 'message_queue_data 'off_heap)
  (loop instance handler batch-size failure-policy mode
        #M(batches 0 handled 0 failed 0 mode mode)))

(defun loop (instance handler batch-size failure-policy mode stats)
  (receive
    ((tuple '$wiregrid envelope)
      (let* ((batch (wiregrid_mailbox:collect envelope batch-size))
             (ordered (wiregrid_mailbox:order batch mode)))
        (handle-batch instance handler batch-size failure-policy mode stats ordered)))

    ((tuple 'wiregrid_worker 'call from ref 'stats)
      (: erlang send from (tuple 'wiregrid_worker ref (tuple 'ok stats)))
      (loop instance handler batch-size failure-policy mode stats))

    ((tuple 'wiregrid_worker 'call from ref 'stop)
      (: erlang send from (tuple 'wiregrid_worker ref 'ok))
      'ok)

    ((tuple 'wiregrid_worker 'cast 'hibernate)
      (: proc_lib hibernate 'wiregrid_worker 'wake
         (list instance handler batch-size failure-policy mode stats)))

    (_other
      ;; This worker owns its mailbox; discard unrelated messages so they cannot
      ;; accumulate forever and starve delivery traffic.
      (loop instance handler batch-size failure-policy mode stats))))

(defun wake (instance handler batch-size failure-policy mode stats)
  (loop instance handler batch-size failure-policy mode stats))

(defun handle-batch (instance handler batch-size failure-policy mode stats batch)
  (case (wiregrid_api:consume_many_deliveries instance batch handler)
    ((tuple 'ok result)
      (case (andalso (=:= failure-policy 'crash)
                     (> (: maps get 'failed result 0) 0))
        ('true (: erlang exit (tuple 'wiregrid_worker_failed result)))
        ('false
          (loop instance handler batch-size failure-policy mode
                (merge-result stats result)))))
    ((tuple 'error result)
      (case (=:= failure-policy 'crash)
        ('true (: erlang exit (tuple 'wiregrid_worker_failed result)))
        ('false
          (loop instance handler batch-size failure-policy mode
                (merge-error stats result (: erlang length batch))))))
    (other
      (: erlang exit (tuple 'wiregrid_worker_invalid_result other)))))

;; Bounded mailbox collection and burst ordering live in wiregrid_mailbox so
;; ordinary and batch-specialized workers share exactly one implementation.

(defun valid-mode (mode)
  (case (orelse (=:= mode 'fifo) (=:= mode 'durable_first))
    ('true 'ok)
    ('false (tuple 'error 'invalid_mode))))

(defun request (pid operation timeout)
  (case (andalso (is_pid pid) (is_integer timeout) (> timeout 0))
    ('true
      (let ((ref (: erlang make_ref)))
        (: erlang send pid (tuple 'wiregrid_worker 'call (self) ref operation))
        (receive
          ((tuple 'wiregrid_worker ref reply) reply)
          (after timeout (tuple 'error 'timeout)))))
    ('false (tuple 'error 'invalid_call))))

(defun valid-options (handler batch-size failure-policy)
  (cond
    ((not (is_function handler 2)) (tuple 'error 'invalid_handler))
    ((not (is_integer batch-size)) (tuple 'error 'invalid_batch_size))
    ((=< batch-size 0) (tuple 'error 'invalid_batch_size))
    ((> batch-size 4096) (tuple 'error 'batch_size_too_large))
    ((not (orelse (=:= failure-policy 'continue) (=:= failure-policy 'crash)))
      (tuple 'error 'invalid_failure_policy))
    ('true 'ok)))


(defun merge-result (stats result)
  ;; Merge counters into the existing stats map instead of rebuilding it.
  ;; Worker metadata such as `mode` must survive every batch. Keeping the map
  ;; extensible also lets future operational counters be added without every
  ;; update path needing to know about them.
  (: maps merge stats
     #M(batches (+ (: maps get 'batches stats 0) 1)
        handled (+ (: maps get 'handled stats 0)
                   (: maps get 'handled result 0))
        failed (+ (: maps get 'failed stats 0)
                  (: maps get 'failed result 0)))))

(defun merge-error (stats result batch-count)
  ;; Canonical consume-many errors may be atoms/tuples (for example an
  ;; instance disappearing during shutdown), not only result maps. Preserve
  ;; all worker metadata in `continue` mode and retain the last failure for
  ;; operators.
  (case (is_map result)
    ('true
      (: maps merge stats
         #M(batches (+ (: maps get 'batches stats 0) 1)
            handled (+ (: maps get 'handled stats 0)
                       (: maps get 'handled result 0))
            failed (+ (: maps get 'failed stats 0)
                      (max-one (: maps get 'failed result 0)))
            last_error result)))
    ('false
      (: maps merge stats
         #M(batches (+ (: maps get 'batches stats 0) 1)
            handled (: maps get 'handled stats 0)
            failed (+ (: maps get 'failed stats 0) (max-one batch-count))
            last_error result)))))

(defun max-one (value)
  (if (> value 0) value 1))
