defmodule Wiregrid.RequestReply do
  @moduledoc """
  Generic request/reply correlation over normal Wiregrid session delivery.

  Wiregrid does not own the application request or response schema. Correlation
  data lives in the delivery envelope under `:context`, while `:event`/`:payload`
  remain exactly the application value selected by the configured codec.

  No pending-request process or table is created: request IDs are opaque UUIDv7
  values and replies reuse ordinary bounded delivery/backpressure semantics.
  """

  @options [:class]

  @spec request_session(term(), binary(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request_session(instance, requester_session, target_session, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @options),
         :ok <- Wiregrid.Validation.session_id(requester_session, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.session_id(target_session, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- delivery_class(Keyword.get(opts, :class, :durable)),
         [{^requester_session, requester}] <- :ets.lookup(t.sessions, requester_session),
         :ok <-
           Wiregrid.Authorizer.check(
             instance,
             cfg,
             :request_session,
             requester,
             target_session,
             %{}
           ),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      request_id = Wiregrid.ID.generate()

      context = %{
        kind: :request,
        request_id: request_id,
        reply_to_session: requester_session
      }

      outcome =
        Wiregrid.Delivery.send_session(
          instance,
          target_session,
          {:custom, :request, request_id},
          payload,
          event,
          class,
          delivery_context: context
        )

      case outcome do
        :sent -> {:ok, %{request_id: request_id, delivery: :sent}}
        other -> {:error, {:delivery_failed, other}}
      end
    else
      [] -> {:error, :unknown_requester_session}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @spec reply(term(), binary(), map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def reply(instance, replier_session, request_envelope, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @options),
         :ok <- Wiregrid.Validation.session_id(replier_session, cfg.max_session_id_bytes),
         {:ok, request_id, reply_to_session} <-
           request_identity(request_envelope, replier_session, cfg),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- delivery_class(Keyword.get(opts, :class, :durable)),
         [{^replier_session, replier}] <- :ets.lookup(t.sessions, replier_session),
         :ok <-
           Wiregrid.Authorizer.check(
             instance,
             cfg,
             :reply_session,
             replier,
             reply_to_session,
             %{request_id: request_id}
           ),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      context = %{kind: :reply, request_id: request_id}

      outcome =
        Wiregrid.Delivery.send_session(
          instance,
          reply_to_session,
          {:custom, :reply, request_id},
          payload,
          event,
          class,
          delivery_context: context
        )

      case outcome do
        :sent -> {:ok, %{request_id: request_id, delivery: :sent}}
        other -> {:error, {:delivery_failed, other}}
      end
    else
      [] -> {:error, :unknown_replier_session}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @spec context(map()) :: {:ok, map()} | {:error, term()}
  def context(%{context: %{kind: kind, request_id: request_id} = context})
      when kind in [:request, :reply] and is_binary(request_id),
      do: {:ok, context}

  def context(_), do: {:error, :not_request_reply_delivery}

  defp request_identity(%{session_id: replier_session, context: context}, replier_session, cfg)
       when is_map(context) do
    with :request <- Map.get(context, :kind),
         request_id when is_binary(request_id) <- Map.get(context, :request_id),
         reply_to when is_binary(reply_to) <- Map.get(context, :reply_to_session),
         :ok <- Wiregrid.Validation.binary_id(request_id, cfg.max_storage_id_bytes),
         :ok <- Wiregrid.Validation.session_id(reply_to, cfg.max_session_id_bytes) do
      {:ok, request_id, reply_to}
    else
      _ -> {:error, :invalid_request_envelope}
    end
  end

  defp request_identity(_envelope, _replier_session, _cfg),
    do: {:error, :invalid_request_envelope}

  defp delivery_class(class) when class in [:durable, :ephemeral], do: {:ok, class}
  defp delivery_class(_), do: {:error, :invalid_event_class}

  defp accepting(instance), do: Wiregrid.Runtime.accepting(instance)
end
