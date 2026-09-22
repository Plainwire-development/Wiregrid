;; Pure helpers for macro-compiled Wiregrid authorizers.
;;
;; This module deliberately performs no calls back into Wiregrid. Authorization
;; callbacks may execute from the runtime control plane; recursively calling
;; lifecycle APIs from an authorizer can deadlock or create surprising ordering.
;; Keep policy evaluation pure and derive decisions from the validated session,
;; resource and context passed to authorize/4.
(defmodule wiregrid_policy
  (export all))

(defun allow () 'true)
(defun deny () 'false)
(defun deny (reason) (tuple 'error reason))

(defun user-id (session)
  (map-get session 'user_id 'undefined))

(defun session-id (session)
  (map-get session 'id 'undefined))

(defun session-metadata (session)
  (case (map-get session 'metadata #M())
    (value (if (is_map value) value #M()))))

(defun presence-metadata (session)
  (case (map-get session 'presence_metadata #M())
    (value (if (is_map value) value #M()))))

(defun context-value (context key default)
  (map-get context key default))

(defun metadata-value (session key default)
  (map-get (session-metadata session) key default))

(defun same-user? (session expected-user)
  (=:= (user-id session) expected-user))

(defun metadata-eq? (session key expected)
  (=:= (metadata-value session key 'undefined) expected))

(defun context-eq? (context key expected)
  (=:= (context-value context key 'undefined) expected))

(defun all (predicates)
  (case predicates
    (() 'true)
    ((cons value rest)
      (andalso (=:= value 'true) (all rest)))))

(defun any (predicates)
  (case predicates
    (() 'false)
    ((cons value rest)
      (orelse (=:= value 'true) (any rest)))))

(defun normalize
  (('ok) 'true)
  (('true) 'true)
  (('false) 'false)
  (((tuple 'error _reason) = decision) decision)
  ((_other) (tuple 'error 'authorization_failed)))

(defun map-get (value key default)
  (case (is_map value)
    ('true (: maps get key value default))
    ('false default)))

;; Topic/resource helpers for compiled policies. These functions operate only on
;; already-validated ordinary terms and never create atoms or call Wiregrid.
(defun topic-kind (resource)
  (case resource
    ((tuple kind _) kind)
    ((tuple kind _ _) kind)
    (_ 'undefined)))

(defun topic-value (resource)
  (case resource
    ((tuple _ value) value)
    ((tuple _ _ value) value)
    (_ 'undefined)))

(defun custom-topic-namespace (resource)
  (case resource
    ((tuple 'custom namespace _value) namespace)
    (_ 'undefined)))

(defun resource-eq? (resource expected)
  (=:= resource expected))

(defun member? (value values)
  (case values
    (() 'false)
    ((cons head rest)
      (orelse (=:= value head) (member? value rest)))))

(defun metadata-member? (session key allowed)
  (member? (metadata-value session key 'undefined) allowed))

(defun context-member? (context key allowed)
  (member? (context-value context key 'undefined) allowed))

(defun allow-if (predicate)
  (case (=:= predicate 'true)
    ('true 'true)
    ('false 'false)))

(defun deny-unless (predicate reason)
  (case (=:= predicate 'true)
    ('true 'true)
    ('false (tuple 'error reason))))
