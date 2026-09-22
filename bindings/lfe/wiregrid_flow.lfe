;; Composite bounded LFE acceleration flows.
;;
;; This module deliberately composes existing canonical helpers rather than
;; inventing another delivery protocol: ephemeral coalescing ACKs only
;; superseded reservations, then ordered lanes decode/handle/ACK the selected
;; deliveries. Durable envelopes are never coalesced and per-lane ordering is
;; preserved by wiregrid_lane.
(defmodule wiregrid_flow
  (export all))

(defun consume-coalesced-lanes
  (instance envelopes coalesce-keyfun lane-keyfun handler lane-count)
  (consume-coalesced-lanes instance envelopes coalesce-keyfun lane-keyfun
                           handler lane-count 5000))

(defun consume-coalesced-lanes
  (instance envelopes coalesce-keyfun lane-keyfun handler lane-count timeout-ms)
  (case (wiregrid_coalesce:latest instance envelopes coalesce-keyfun)
    ((tuple 'ok selected-info)
      (let ((selected (: maps get 'envelopes selected-info ())))
        (case (wiregrid_lane:consume instance selected lane-keyfun handler
                                    lane-count timeout-ms)
          ((tuple 'ok lane-info)
            (tuple 'ok
                   (: maps merge lane-info
                      #M(input (: erlang length envelopes)
                         selected (: erlang length selected)
                         coalesced (: maps get 'coalesced selected-info 0)
                         superseded_acks (: maps get 'acks selected-info #M())))))
          (error
            (tuple 'error #M(stage 'lanes
                            input (: erlang length envelopes)
                            selected (: erlang length selected)
                            coalesced (: maps get 'coalesced selected-info 0)
                            superseded_acks (: maps get 'acks selected-info #M())
                            cause error))))))
    (error
      (tuple 'error #M(stage 'coalesce cause error)))))

;; Common chat/collaboration profiles. They are ordinary functions so callers
;; can use them directly or freeze them into generated worker modules with the
;; macros in wiregrid_macros.
(defun session-topic-by-session
  (instance envelopes handler lane-count timeout-ms)
  (consume-coalesced-lanes instance envelopes
                           (fun wiregrid_coalesce key-session-topic 1)
                           (fun wiregrid_lane key-session 1)
                           handler lane-count timeout-ms))

(defun topic-by-session
  (instance envelopes handler lane-count timeout-ms)
  (consume-coalesced-lanes instance envelopes
                           (fun wiregrid_coalesce key-topic 1)
                           (fun wiregrid_lane key-session 1)
                           handler lane-count timeout-ms))

(defun request-by-request
  (instance envelopes handler lane-count timeout-ms)
  (consume-coalesced-lanes instance envelopes
                           (fun wiregrid_coalesce key-request 1)
                           (fun wiregrid_lane key-request 1)
                           handler lane-count timeout-ms))
