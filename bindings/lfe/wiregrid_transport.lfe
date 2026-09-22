;; Helpers for Wiregrid.Transport.Command extension handlers written in LFE.
;; Context is deliberately sanitized by the canonical router and contains only
;; instance/session/user identity; transport credentials are never exposed.
(defmodule wiregrid_transport
  (export all))

(defun instance (context) (: maps get 'instance context 'undefined))
(defun session-id (context) (: maps get 'session_id context 'undefined))
(defun user-id (context) (: maps get 'user_id context 'undefined))

(defun actor (context)
  (let ((instance (instance context))
        (session (session-id context))
        (user (user-id context)))
    (case (andalso (not (=:= instance 'undefined))
                   (is_binary session)
                   (not (=:= user 'undefined)))
      ('true (tuple 'ok #M(instance instance session_id session user_id user)))
      ('false (tuple 'error 'invalid_transport_context)))))

(defun reply-error (reason) (tuple 'error reason))
(defun reply-ok (value) (tuple 'ok value))
