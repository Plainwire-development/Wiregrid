defmodule Wiregrid.Codec do
  @moduledoc "Behaviour and guarded invocation for event codecs."

  @callback encode(term()) :: {:ok, binary()} | {:error, term()}
  @callback decode(binary()) :: {:ok, term()} | {:error, term()}

  def encode(cfg, event) do
    try do
      case cfg.codec.encode(event) do
        {:ok, binary}
        when is_binary(binary) and byte_size(binary) <= cfg.max_encoded_event_bytes ->
          {:ok, binary}

        {:ok, binary} when is_binary(binary) ->
          {:error, :encoded_event_too_large}

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_codec_result}
      end
    rescue
      _ -> {:error, :codec_failed}
    catch
      _, _ -> {:error, :codec_failed}
    end
  end

  def decode(cfg, binary)
      when is_binary(binary) and byte_size(binary) <= cfg.max_encoded_event_bytes do
    try do
      case cfg.codec.decode(binary) do
        {:ok, value} -> {:ok, value}
        {:error, _} = error -> error
        _ -> {:error, :invalid_codec_result}
      end
    rescue
      _ -> {:error, :codec_failed}
    catch
      _, _ -> {:error, :codec_failed}
    end
  end

  def decode(_cfg, _), do: {:error, :encoded_event_too_large}
end
