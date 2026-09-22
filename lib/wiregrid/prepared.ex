defmodule Wiregrid.Prepared do
  @moduledoc """
  Opaque, integrity-bound prepared event handles.

  Preparing validates and encodes an event once. The returned tuple may then
  be reused by prepared publish/send APIs when the instance still uses the same
  codec. A per-instance HMAC binds the decoded term, codec and encoded payload,
  so callers cannot splice a different event or payload into a prepared handle
  and make persistence disagree with delivery.

  The MAC key is generated when the instance supervisor starts and is never
  exposed through the public API. Handles therefore intentionally become
  invalid if an instance supervisor is stopped and replaced.
  """

  @tag :wiregrid_prepared_v2
  @type t :: {:wiregrid_prepared_v2, module(), term(), binary(), binary()}

  @spec prepare(term(), term()) :: {:ok, t()} | {:error, term()}
  def prepare(instance, event) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      mac = sign(cfg, cfg.codec, event, payload)
      {:ok, {@tag, cfg.codec, event, payload, mac}}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec unpack(term(), term()) :: {:ok, term(), binary()} | {:error, term()}
  def unpack(instance, {@tag, codec, event, payload, mac})
      when is_atom(codec) and is_binary(payload) and is_binary(mac) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         true <- codec == cfg.codec,
         true <- byte_size(payload) <= cfg.max_encoded_event_bytes,
         true <- byte_size(mac) == 32,
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         expected <- sign(cfg, codec, event, payload),
         true <- :crypto.hash_equals(expected, mac) do
      {:ok, event, payload}
    else
      :undefined -> {:error, :instance_unavailable}
      false -> {:error, :prepared_event_mismatch}
      {:error, _} = error -> error
    end
  end

  def unpack(_instance, _prepared), do: {:error, :invalid_prepared_event}

  defp sign(%{prepared_mac_key: key}, codec, event, payload) when byte_size(key) == 32 do
    encoded = :erlang.term_to_binary({codec, event, payload}, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, encoded)
  end
end
