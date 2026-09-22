defmodule Wiregrid.Chat.Config do
  @moduledoc false

  @defaults %{
    max_message_bytes: 64 * 1024,
    max_attachment_count: 32,
    max_mention_count: 100,
    max_reaction_bytes: 64,
    max_client_nonce_bytes: 128,
    max_chat_event_bytes: 262_144,
    message_rate_limit: {30, 10_000},
    activity_rate_limit: {60, 10_000},
    allow_empty_messages_with_attachments: true
  }

  @keys Map.keys(@defaults)

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @keys,
         cfg <- Map.merge(@defaults, Map.new(opts)),
         :ok <- validate(cfg) do
      {:ok, cfg}
    else
      false -> {:error, :invalid_chat_options}
      unknown when is_list(unknown) -> {:error, {:unknown_chat_options, Enum.uniq(unknown)}}
      {:error, _} = error -> error
    end
  end

  def build(_), do: {:error, :invalid_chat_options}

  @spec build!(keyword()) :: map()
  def build!(opts) do
    case build(opts) do
      {:ok, cfg} -> cfg
      {:error, reason} -> raise ArgumentError, "invalid Wiregrid.Chat options: #{inspect(reason)}"
    end
  end

  defp validate(cfg) do
    positive = [
      :max_message_bytes,
      :max_attachment_count,
      :max_mention_count,
      :max_reaction_bytes,
      :max_client_nonce_bytes,
      :max_chat_event_bytes
    ]

    cond do
      Enum.any?(positive, &(not is_integer(Map.fetch!(cfg, &1)) or Map.fetch!(cfg, &1) <= 0)) ->
        {:error, :invalid_chat_limits}

      cfg.max_message_bytes > 1_048_576 or cfg.max_chat_event_bytes > 1_048_576 ->
        {:error, :message_limit_too_large}

      cfg.max_chat_event_bytes < cfg.max_message_bytes ->
        {:error, :chat_event_limit_too_small}

      cfg.max_attachment_count > 256 or cfg.max_mention_count > 10_000 ->
        {:error, :chat_collection_limit_too_large}

      not valid_rate?(cfg.message_rate_limit) or not valid_rate?(cfg.activity_rate_limit) ->
        {:error, :invalid_chat_rate_limit}

      not is_boolean(cfg.allow_empty_messages_with_attachments) ->
        {:error, :invalid_empty_message_policy}

      true ->
        :ok
    end
  end

  defp valid_rate?(nil), do: true

  defp valid_rate?({limit, window})
       when is_integer(limit) and limit > 0 and limit <= 100_000 and is_integer(window) and
              window >= 100 and window <= 3_600_000,
       do: true

  defp valid_rate?(_), do: false
end
