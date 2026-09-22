;; Bounded mailbox primitives shared by Wiregrid's optional LFE workers.
;;
;; These functions deliberately collect only a fixed prefix of already-arrived
;; deliveries. No function performs an unbounded selective-receive scan. A small
;; optional wait can be used to form micro-batches when throughput matters more
;; than single-message latency; the caller controls that bound explicitly.
(defmodule wiregrid_mailbox
  (export all))

(defun collect (first limit)
  (case (valid-limit limit)
    ('ok (collect-loop (list first) (- limit 1) 0))
    (error error)))

(defun collect-wait (first limit wait-ms)
  (case (valid-limit limit)
    ('ok
      (case (valid-wait wait-ms)
        ('ok (collect-loop (list first) (- limit 1) wait-ms))
        (error error)))
    (error error)))

(defun collect-loop
  ((acc 0 _wait-ms)
    (: lists reverse acc))
  ((acc remaining wait-ms)
    (receive
      ((tuple '$wiregrid envelope)
        ;; Once a second item arrives, drain only already-arrived messages. This
        ;; gives one bounded coalescing delay per burst rather than per item.
        (collect-loop (cons envelope acc) (- remaining 1) 0))
      (after wait-ms
        (: lists reverse acc)))))

;; Priority applies only inside the bounded batch already removed from the
;; mailbox. Relative order is stable within each class.
(defun order
  ((batch 'fifo) batch)
  ((batch 'durable_first)
    (let (((tuple durable other) (partition-class batch () ())))
      (: lists append (list (: lists reverse durable) (: lists reverse other)))))
  ((_batch mode)
    (tuple 'error (tuple 'invalid_mode mode))))

(defun class-counts (batch)
  (class-counts batch 0 0))
(defun class-counts
  ((() durable ephemeral)
    #M(durable durable ephemeral ephemeral))
  (((cons envelope rest) durable ephemeral)
    (case (: maps get 'class envelope 'durable)
      ('durable (class-counts rest (+ durable 1) ephemeral))
      ('ephemeral (class-counts rest durable (+ ephemeral 1)))
      (_ (class-counts rest durable ephemeral)))))

(defun partition-class
  ((() durable other)
    (tuple durable other))
  (((cons envelope rest) durable other)
    (case (: maps get 'class envelope 'durable)
      ('durable (partition-class rest (cons envelope durable) other))
      (_ (partition-class rest durable (cons envelope other))))))

(defun valid-limit (limit)
  (case (andalso (is_integer limit) (> limit 0) (=< limit 4096))
    ('true 'ok)
    ('false (tuple 'error 'invalid_batch_size))))

(defun valid-wait (wait-ms)
  ;; Micro-batching waits are intentionally tiny; larger buffering belongs in
  ;; application storage/queues, not a realtime owner process mailbox.
  (case (andalso (is_integer wait-ms) (>= wait-ms 0) (=< wait-ms 50))
    ('true 'ok)
    ('false (tuple 'error 'invalid_collect_wait))))
