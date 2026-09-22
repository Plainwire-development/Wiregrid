defmodule Wiregrid.Webhook.Signature do
  import Bitwise

  @moduledoc """
  Shared webhook HMAC signing and verification primitives.

  Wiregrid signs the exact byte sequence:

      timestamp <> "." <> nonce <> "." <> delivery_id <> "." <> body

  using HMAC-SHA256 and exposes the digest as `v1=<lowercase hex>`. Receivers
  should verify the signature and timestamp, then enforce nonce/delivery-ID
  replay protection in their own durable store if they require exactly-once
  side effects. Wiregrid deliberately does not maintain remote replay state.
  """

  @max_secret_bytes 256
  @min_secret_bytes 32
  @max_id_bytes 256
  @max_nonce_bytes 128
  @default_max_body_bytes 1_048_576
  @absolute_max_body_bytes 16_777_216
  @default_max_skew_seconds 300
  @verify_options [:now, :max_skew_seconds, :max_body_bytes]

  @spec sign(binary(), binary(), binary(), integer() | binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign(secret, delivery_id, body, timestamp, nonce) do
    with :ok <- validate_secret(secret),
         :ok <- bounded_binary(delivery_id, 1, @max_id_bytes, :invalid_webhook_id),
         :ok <- bounded_binary(body, 0, @absolute_max_body_bytes, :webhook_body_too_large),
         {:ok, timestamp_text, _timestamp_int} <- normalize_timestamp(timestamp),
         :ok <- bounded_binary(nonce, 1, @max_nonce_bytes, :invalid_webhook_nonce) do
      payload = signature_payload(timestamp_text, nonce, delivery_id, body)
      digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
      {:ok, "v1=" <> digest}
    end
  end

  @spec verify(binary(), binary(), binary(), binary(), integer() | binary(), binary(), keyword()) ::
          :ok | {:error, term()}
  def verify(signature, secret, delivery_id, body, timestamp, nonce, opts \\ []) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @verify_options),
         :ok <- bounded_binary(signature, 67, 67, :invalid_webhook_signature),
         :ok <- validate_secret(secret),
         :ok <- bounded_binary(delivery_id, 1, @max_id_bytes, :invalid_webhook_id),
         {:ok, max_body_bytes} <- max_body_bytes(opts),
         :ok <- bounded_binary(body, 0, max_body_bytes, :webhook_body_too_large),
         {:ok, timestamp_text, timestamp_int} <- normalize_timestamp(timestamp),
         :ok <- bounded_binary(nonce, 1, @max_nonce_bytes, :invalid_webhook_nonce),
         {:ok, now} <- now(opts),
         {:ok, skew} <- max_skew(opts),
         :ok <- within_window(timestamp_int, now, skew),
         {:ok, expected} <-
           sign_with_limit(secret, delivery_id, body, timestamp_text, nonce, max_body_bytes),
         true <- secure_compare(signature, expected) do
      :ok
    else
      false -> {:error, :invalid_webhook_signature}
      {:error, _} = error -> error
    end
  end

  defp sign_with_limit(secret, delivery_id, body, timestamp_text, nonce, max_body_bytes) do
    with :ok <- validate_secret(secret),
         :ok <- bounded_binary(delivery_id, 1, @max_id_bytes, :invalid_webhook_id),
         :ok <- bounded_binary(body, 0, max_body_bytes, :webhook_body_too_large),
         :ok <- bounded_binary(nonce, 1, @max_nonce_bytes, :invalid_webhook_nonce) do
      payload = signature_payload(timestamp_text, nonce, delivery_id, body)
      digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      {:ok, "v1=" <> digest}
    end
  end

  defp signature_payload(timestamp, nonce, delivery_id, body),
    do: timestamp <> "." <> nonce <> "." <> delivery_id <> "." <> body

  defp normalize_timestamp(value) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value), value}

  defp normalize_timestamp(value) when is_binary(value) and byte_size(value) in 1..20 do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, value, int}
      _ -> {:error, :invalid_webhook_timestamp}
    end
  end

  defp normalize_timestamp(_), do: {:error, :invalid_webhook_timestamp}

  defp validate_secret(secret)
       when is_binary(secret) and byte_size(secret) >= @min_secret_bytes and
              byte_size(secret) <= @max_secret_bytes,
       do: :ok

  defp validate_secret(_), do: {:error, :invalid_webhook_secret}

  defp max_body_bytes(opts) do
    case Keyword.get(opts, :max_body_bytes, @default_max_body_bytes) do
      value when is_integer(value) and value > 0 and value <= @absolute_max_body_bytes ->
        {:ok, value}

      _ ->
        {:error, :invalid_webhook_body_limit}
    end
  end

  defp max_skew(opts) do
    case Keyword.get(opts, :max_skew_seconds, @default_max_skew_seconds) do
      value when is_integer(value) and value >= 0 and value <= 86_400 -> {:ok, value}
      _ -> {:error, :invalid_webhook_skew}
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now, System.system_time(:second)) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_webhook_now}
    end
  end

  defp within_window(timestamp, now, skew) do
    if abs(now - timestamp) <= skew, do: :ok, else: {:error, :webhook_timestamp_outside_window}
  end

  defp bounded_binary(value, min, max, _error)
       when is_binary(value) and byte_size(value) >= min and byte_size(value) <= max,
       do: :ok

  defp bounded_binary(_value, _min, _max, error), do: {:error, error}

  # Compare every byte when sizes match. Signatures are fixed at 67 bytes, so
  # this has a stable amount of work and does not reveal the first mismatch.
  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    secure_compare(left, right, 0) == 0
  end

  defp secure_compare(_, _), do: false

  defp secure_compare(<<>>, <<>>, acc), do: acc

  defp secure_compare(<<a, rest_a::binary>>, <<b, rest_b::binary>>, acc),
    do: secure_compare(rest_a, rest_b, bor(acc, bxor(a, b)))
end
