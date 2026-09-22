defmodule Wiregrid.Signaling do
  @moduledoc "Generic room-scoped WebRTC/collaboration signaling primitives."

  @kinds [
    :ring,
    :accept,
    :decline,
    :cancel,
    :offer,
    :answer,
    :ice_candidate,
    :leave,
    :reconnect,
    :membership
  ]

  def send(instance, room, session_id, kind, payload, opts \\ [])

  def send(instance, room, session_id, kind, payload, opts)
      when kind in @kinds and is_list(opts) do
    with %{tables: t, config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, [:include_sender]),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         {:ok, include_sender} <- boolean_opt(Keyword.get(opts, :include_sender, false)),
         [{^session_id, session}] <- :ets.lookup(t.sessions, session_id),
         true <- :ets.member(t.room_edges, {room, session_id}),
         :ok <- Wiregrid.Validation.event(payload, cfg.max_metadata_bytes),
         :ok <-
           Wiregrid.Authorizer.check(instance, cfg, {:signal, kind}, session, room, %{
             payload: payload
           }) do
      event = %{
        type: :signal,
        signal: kind,
        from_user_id: session.user_id,
        from_session_id: session_id,
        payload: payload
      }

      exclusions = if include_sender, do: [], else: [session_id]

      Wiregrid.publish_room(instance, room, event,
        class: :durable,
        session_id: session_id,
        exclude_sessions: exclusions,
        cluster: true
      )
    else
      false -> {:error, :not_room_member}
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  def send(_instance, _room, _session_id, _kind, _payload, _opts), do: {:error, :invalid_signal}

  defp boolean_opt(value) when is_boolean(value), do: {:ok, value}
  defp boolean_opt(_), do: {:error, :invalid_include_sender}
end
