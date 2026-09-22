defmodule Wiregrid.Chat.Event do
  @moduledoc """
  Bounded constructors for conventional chat events.

  These helpers deliberately return plain maps so transports and storage remain
  application-neutral. Constructors enforce inexpensive boundary checks before
  an event reaches the realtime fanout path.
  """

  @type config :: map()
  @message_options [:attachments, :mentions, :metadata, :nonce, :reply_to]

  @spec message(term(), keyword(), config()) :: {:ok, map()} | {:error, term()}
  def message(body, opts, cfg) when is_list(opts) and is_map(cfg) do
    with :ok <- validate_options(opts) do
      build_message(body, opts, cfg)
    end
  end

  def message(_, _, _), do: {:error, :invalid_message}

  defp build_message(body, opts, cfg) do
    attachments = Keyword.get(opts, :attachments, [])
    mentions = Keyword.get(opts, :mentions, [])
    metadata = Keyword.get(opts, :metadata, %{})
    nonce = Keyword.get(opts, :nonce)

    with {:ok, body} <- body(body, cfg.max_message_bytes),
         :ok <- bounded_list(attachments, cfg.max_attachment_count, :attachments),
         :ok <- bounded_list(mentions, cfg.max_mention_count, :mentions),
         :ok <- bounded_map(metadata, 128, :metadata),
         :ok <- optional_binary(nonce, cfg.max_client_nonce_bytes, :nonce),
         :ok <- non_empty_message(body, attachments, cfg) do
      event =
        compact(%{
          type: :message,
          body: body,
          attachments: attachments,
          mentions: mentions,
          metadata: metadata,
          nonce: nonce,
          reply_to: Keyword.get(opts, :reply_to)
        })

      with :ok <- Wiregrid.Validation.event(event, cfg.max_chat_event_bytes), do: {:ok, event}
    end
  end

  @spec edit(term(), term(), config()) :: {:ok, map()} | {:error, term()}
  def edit(message_id, body, cfg) do
    with :ok <- identifier(message_id, 256, :message_id),
         {:ok, body} <- body(body, cfg.max_message_bytes),
         true <- body != "" do
      event = %{type: :message_edit, message_id: message_id, body: body}
      with :ok <- Wiregrid.Validation.event(event, cfg.max_chat_event_bytes), do: {:ok, event}
    else
      false -> {:error, :empty_message}
      {:error, _} = error -> error
    end
  end

  @spec delete(term(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def delete(message_id, reason \\ nil) do
    with :ok <- identifier(message_id, 256, :message_id),
         :ok <- optional_binary(reason, 512, :reason) do
      {:ok, compact(%{type: :message_delete, message_id: message_id, reason: reason})}
    end
  end

  @spec reaction(term(), term(), boolean(), config()) :: {:ok, map()} | {:error, term()}
  def reaction(message_id, emoji, add?, cfg) when is_boolean(add?) do
    with :ok <- identifier(message_id, 256, :message_id),
         {:ok, emoji} <- body(emoji, cfg.max_reaction_bytes),
         true <- emoji != "" do
      event = %{
        type: if(add?, do: :reaction_add, else: :reaction_remove),
        message_id: message_id,
        reaction: emoji
      }

      with :ok <- Wiregrid.Validation.event(event, cfg.max_chat_event_bytes), do: {:ok, event}
    else
      false -> {:error, :empty_reaction}
      {:error, _} = error -> error
    end
  end

  @spec read(term()) :: {:ok, map()} | {:error, term()}
  def read(message_id) do
    with :ok <- identifier(message_id, 256, :message_id) do
      {:ok, %{type: :read, message_id: message_id}}
    end
  end

  @spec typing(boolean()) :: map()
  def typing(active?) when is_boolean(active?), do: %{type: :typing, active: active?}

  defp validate_options(opts) do
    with :ok <- Wiregrid.Validation.bounded_list(opts, 64),
         true <- Keyword.keyword?(opts),
         keys <- Keyword.keys(opts),
         [] <- keys -- @message_options,
         true <- length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      _ -> {:error, :invalid_message_options}
    end
  end

  defp body(value, max) when is_binary(value) do
    value = String.trim(value)
    if byte_size(value) <= max, do: {:ok, value}, else: {:error, :message_too_large}
  end

  defp body(_value, _max), do: {:error, :invalid_message_body}

  defp non_empty_message("", [], %{allow_empty_messages_with_attachments: _}),
    do: {:error, :empty_message}

  defp non_empty_message("", _attachments, %{allow_empty_messages_with_attachments: false}),
    do: {:error, :empty_message}

  defp non_empty_message(_, _, _), do: :ok

  defp bounded_list(value, max, field) when is_list(value),
    do: bounded_list_count(value, max, field)

  defp bounded_list(_value, _max, field), do: {:error, {:invalid_or_too_many, field}}

  defp bounded_list_count([], _remaining, _field), do: :ok

  defp bounded_list_count([_ | tail], remaining, field) when remaining > 0,
    do: bounded_list_count(tail, remaining - 1, field)

  defp bounded_list_count(_rest, 0, field), do: {:error, {:invalid_or_too_many, field}}

  defp bounded_map(value, max, _field) when is_map(value) and map_size(value) <= max, do: :ok
  defp bounded_map(_value, _max, field), do: {:error, {:invalid_or_too_many, field}}

  defp optional_binary(nil, _max, _field), do: :ok

  defp optional_binary(value, max, _field) when is_binary(value) and byte_size(value) <= max,
    do: :ok

  defp optional_binary(_value, _max, field), do: {:error, {:invalid, field}}

  defp identifier(value, max, _field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max, do: :ok

  defp identifier(value, _max, _field) when is_integer(value) or is_atom(value), do: :ok
  defp identifier(_value, _max, field), do: {:error, {:invalid, field}}

  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, [], %{}] end)
end
