;; Restart-aware reusable dispatch plans for high-throughput LFE applications.
;;
;; Wiregrid dispatch plans are integrity-bound to one running instance. This
;; helper keeps the opaque plan together with the original bounded target set
;; and recompiles exactly once when an instance restart invalidates the old
;; plan. Authorization, persistence, drain state and backpressure are still
;; evaluated by the canonical runtime on every dispatch.
(defmodule wiregrid_plan
  (export all))

(defun new (instance targets)
  (case (wiregrid_api:compile_dispatch instance targets)
    ((tuple 'ok plan)
      (tuple 'ok #M(instance instance targets targets plan plan)))
    (error error)))

(defun refresh (state)
  (case (state-fields state)
    ((tuple 'ok instance targets _plan)
      (case (wiregrid_api:compile_dispatch instance targets)
        ((tuple 'ok plan)
          (tuple 'ok (: maps put 'plan plan state)))
        (error error)))
    (error error)))

(defun dispatch (state event)
  (dispatch state event ()))

(defun dispatch (state event opts)
  (case (state-fields state)
    ((tuple 'ok instance _targets plan)
      (case (wiregrid_api:dispatch_plan instance plan event opts)
        ((tuple 'error 'invalid_dispatch_plan)
          (retry-dispatch state event opts))
        ((tuple 'ok result)
          (tuple 'ok state result))
        (error error)))
    (error error)))

(defun dispatch-prepared (state prepared)
  (dispatch-prepared state prepared ()))

(defun dispatch-prepared (state prepared opts)
  (case (state-fields state)
    ((tuple 'ok instance _targets plan)
      (case (wiregrid_api:dispatch_plan_prepared instance plan prepared opts)
        ((tuple 'error 'invalid_dispatch_plan)
          (retry-dispatch-prepared state prepared opts))
        ((tuple 'ok result)
          (tuple 'ok state result))
        (error error)))
    (error error)))

(defun targets (state)
  (case (state-fields state)
    ((tuple 'ok _instance targets _plan) (tuple 'ok targets))
    (error error)))

(defun instance (state)
  (case (state-fields state)
    ((tuple 'ok instance _targets _plan) (tuple 'ok instance))
    (error error)))

(defun retry-dispatch (state event opts)
  (case (refresh state)
    ((tuple 'ok fresh)
      (let ((instance (: maps get 'instance fresh))
            (plan (: maps get 'plan fresh)))
        (case (wiregrid_api:dispatch_plan instance plan event opts)
          ((tuple 'ok result) (tuple 'ok fresh result))
          (error error))))
    (error error)))

(defun retry-dispatch-prepared (state prepared opts)
  (case (refresh state)
    ((tuple 'ok fresh)
      (let ((instance (: maps get 'instance fresh))
            (plan (: maps get 'plan fresh)))
        (case (wiregrid_api:dispatch_plan_prepared instance plan prepared opts)
          ((tuple 'ok result) (tuple 'ok fresh result))
          (error error))))
    (error error)))

(defun state-fields (state)
  (case (is_map state)
    ('true
      (case (tuple (: maps find 'instance state)
                   (: maps find 'targets state)
                   (: maps find 'plan state))
        ((tuple (tuple 'ok instance) (tuple 'ok targets) (tuple 'ok plan))
          (tuple 'ok instance targets plan))
        (_ (tuple 'error 'invalid_dispatch_plan_state))))
    ('false (tuple 'error 'invalid_dispatch_plan_state))))
