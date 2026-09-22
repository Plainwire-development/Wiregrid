;; Bounded pre-decode coalescing for drop-safe ephemeral Wiregrid deliveries.
;;
;; Durable deliveries are always retained. Ephemeral deliveries sharing the
;; same caller-defined key collapse to the newest envelope inside one already
;; bounded batch. Superseded envelopes are ACKed without decoding; selected
;; envelopes keep their original relative order and can then be handled through
;; the normal Wiregrid pipeline.
(defmodule wiregrid_coalesce
  (export all))

(defun latest (instance envelopes keyfun)
  (case (validate instance envelopes keyfun)
    ('ok
      (let ((state (collect envelopes keyfun 0 #M() () ())))
        (finish instance state)))
    (error error)))

(defun consume-latest (instance envelopes keyfun handler)
  (case (latest instance envelopes keyfun)
    ((tuple 'ok result)
      (let ((selected (: maps get 'envelopes result ())))
        (case (wiregrid_pipeline:consume-many instance selected handler)
          ((tuple 'ok consumed)
            (tuple 'ok #M(selected (: erlang length selected)
                          coalesced (: maps get 'coalesced result 0)
                          superseded_acks (: maps get 'acks result #M())
                          consumed consumed)))
          (error
            (tuple 'error #M(stage 'consume selected (: erlang length selected)
                            coalesced (: maps get 'coalesced result 0)
                            cause error))))))
    (error error)))

(defun collect
  ((() _keyfun _index latest durable superseded)
    #M(latest latest durable durable superseded superseded))
  (((cons envelope rest) keyfun index latest durable superseded)
    (case (: maps get 'class envelope 'durable)
      ('ephemeral
        (let* ((key (safe-key keyfun envelope))
               (existing (: maps find key latest)))
          (case existing
            ((tuple 'ok (tuple _old-index old-envelope))
              (collect rest keyfun (+ index 1)
                       (: maps put key (tuple index envelope) latest)
                       durable (cons old-envelope superseded)))
            ('error
              (collect rest keyfun (+ index 1)
                       (: maps put key (tuple index envelope) latest)
                       durable superseded)))))
      (_
        (collect rest keyfun (+ index 1) latest
                 (cons (tuple index envelope) durable) superseded)))))

(defun finish (instance state)
  (let* ((latest (: maps values (: maps get 'latest state #M())))
         (durable (: maps get 'durable state ()))
         (selected (sort-indexed (: lists append (list durable latest))))
         (superseded (: maps get 'superseded state ())))
    (case superseded
      (()
        (tuple 'ok #M(envelopes selected coalesced 0 acks #M(acked 0 unknown 0))))
      (_
        (case (wiregrid_fast:ack-grouped instance superseded)
          ((tuple 'ok acks)
            (tuple 'ok #M(envelopes selected
                          coalesced (: erlang length superseded)
                          acks acks)))
          (error
            (tuple 'error #M(stage 'coalesce_ack cause error
                            envelopes selected
                            coalesced (: erlang length superseded)))))))))

(defun sort-indexed (indexed)
  (: lists map
     (lambda ((tuple _index envelope)) envelope)
     (: lists keysort 1 indexed)))

(defun key-topic (envelope)
  (: maps get 'topic envelope (: maps get 'delivery_id envelope 'undefined)))
(defun key-session-topic (envelope)
  (tuple (: maps get 'session_id envelope 'undefined)
         (: maps get 'topic envelope (: maps get 'delivery_id envelope 'undefined))))
(defun key-request (envelope)
  (let ((context (: maps get 'context envelope #M())))
    (: maps get 'request_id context (: maps get 'delivery_id envelope 'undefined))))

(defun safe-key (keyfun envelope)
  (try
    (funcall keyfun envelope)
    (catch
      ((tuple _class _reason _stack)
        (: maps get 'delivery_id envelope 'undefined)))))

(defun validate (instance envelopes keyfun)
  (case (wiregrid_fast:validate-batch instance envelopes)
    ('ok
      (case (validate-envelopes envelopes)
        ('ok
          (case (is_function keyfun 1)
            ('true 'ok)
            ('false (tuple 'error 'invalid_coalesce_key_function))))
        (error error)))
    (error error)))

(defun validate-envelopes
  ((()) 'ok)
  (((cons envelope rest))
    (case (wiregrid_fast:envelope-ack envelope)
      ((tuple 'ok _session _delivery-id) (validate-envelopes rest))
      (error error))))
