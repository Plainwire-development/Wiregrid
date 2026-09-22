defmodule Wiregrid.Transport.Auth do
  @moduledoc "Versioned HMAC transport tokens with audience binding and key rotation."

  @version 1
  @max_token_bytes 2_048
  @nonce_bytes 16
  @signature_bytes 32
  @max_keys 32
  @max_secret_bytes 4_096

  def issue(subject, keys, opts \\ [])

  def issue(subject, secret, opts) when is_binary(secret) do
    issue(subject, %{"0" => secret}, Keyword.put_new(opts, :key_id, "0"))
  end

  def issue(subject, keys, opts) when is_binary(subject) and is_map(keys) and is_list(opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, [:key_id, :audience, :ttl_s]),
         :ok <- validate_keys(keys),
         true <- byte_size(subject) in 1..512,
         {:ok, key_id, secret} <- signing_key(keys, Keyword.get(opts, :key_id)),
         true <- byte_size(key_id) in 1..64,
         true <- byte_size(secret) >= 32,
         audience when is_binary(audience) <- Keyword.get(opts, :audience, "wiregrid"),
         true <- byte_size(audience) in 1..256,
         ttl when is_integer(ttl) and ttl in 1..86_400 <- Keyword.get(opts, :ttl_s, 900) do
      now = System.system_time(:second)
      exp = now + ttl
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)

      payload =
        <<@version, byte_size(key_id)::unsigned-8, key_id::binary, now::unsigned-64,
          exp::unsigned-64, byte_size(audience)::unsigned-16, audience::binary,
          byte_size(subject)::unsigned-16, subject::binary, nonce::binary-size(@nonce_bytes)>>

      signature = :crypto.mac(:hmac, :sha256, secret, payload)
      token = Base.url_encode64(payload <> signature, padding: false)
      if byte_size(token) <= @max_token_bytes, do: {:ok, token}, else: {:error, :token_too_large}
    else
      false -> {:error, :invalid_token_claims}
      {:error, _} = error -> error
      _ -> {:error, :invalid_token_claims}
    end
  end

  def issue(_, _, _), do: {:error, :invalid_token_claims}

  def verify(token, keys, opts \\ [])

  def verify(token, secret, opts) when is_binary(secret),
    do: verify(token, %{"0" => secret}, opts)

  def verify(token, keys, opts) when is_binary(token) and is_map(keys) and is_list(opts) do
    with true <- byte_size(token) <= @max_token_bytes,
         :ok <- Wiregrid.Validation.keyword_opts(opts, [:audience, :clock_skew_s]),
         :ok <- validate_keys(keys),
         {:ok, raw} <- Base.url_decode64(token, padding: false),
         true <- byte_size(raw) > @signature_bytes,
         payload_size <- byte_size(raw) - @signature_bytes,
         <<payload::binary-size(^payload_size), signature::binary-size(@signature_bytes)>> <- raw,
         {:ok, parsed} <- parse_payload(payload),
         {:ok, secret} <- verification_key(keys, parsed.key_id),
         true <- byte_size(secret) >= 32,
         expected <- :crypto.mac(:hmac, :sha256, secret, payload),
         true <- secure_equal(signature, expected),
         :ok <- validate_times(parsed, Keyword.get(opts, :clock_skew_s, 30)),
         :ok <- validate_audience(parsed, Keyword.get(opts, :audience, "wiregrid")) do
      {:ok, Map.drop(parsed, [:key_id]) |> Map.put(:key_id, parsed.key_id)}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_token}

  defp parse_payload(<<@version, kid_len::unsigned-8, rest::binary>>)
       when kid_len > 0 and kid_len <= 64 do
    with <<key_id::binary-size(^kid_len), iat::unsigned-64, exp::unsigned-64,
           aud_len::unsigned-16, tail::binary>> <- rest,
         true <- aud_len > 0 and aud_len <= 256,
         <<audience::binary-size(^aud_len), sub_len::unsigned-16, tail2::binary>> <- tail,
         true <- sub_len > 0 and sub_len <= 512,
         <<subject::binary-size(^sub_len), nonce::binary-size(@nonce_bytes)>> <- tail2 do
      {:ok,
       %{
         key_id: key_id,
         subject: subject,
         audience: audience,
         issued_at: iat,
         expires_at: exp,
         nonce: nonce
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp parse_payload(_), do: {:error, :invalid_payload}

  @doc "Returns the deterministic audience used by the Cowboy adapter for an instance."
  @spec instance_audience(term()) :: binary()
  def instance_audience(instance) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(instance, [:deterministic]))
    "wiregrid-instance:" <> Base.url_encode64(digest, padding: false)
  end

  defp validate_keys(keys) when is_map(keys) and map_size(keys) in 1..@max_keys do
    if Enum.all?(keys, fn
         {key_id, secret}
         when is_binary(key_id) and byte_size(key_id) in 1..64 and is_binary(secret) and
                byte_size(secret) in 32..@max_secret_bytes ->
           true

         _ ->
           false
       end) do
      :ok
    else
      {:error, :invalid_key_ring}
    end
  end

  defp validate_keys(_), do: {:error, :invalid_key_ring}

  defp signing_key(keys, nil) do
    case keys |> Enum.sort_by(fn {key_id, _secret} -> key_id end) |> List.first() do
      {key_id, secret} -> {:ok, key_id, secret}
      nil -> {:error, :no_signing_key}
    end
  end

  defp signing_key(keys, key_id) when is_binary(key_id) do
    case Map.fetch(keys, key_id) do
      {:ok, secret} when is_binary(secret) -> {:ok, key_id, secret}
      _ -> {:error, :unknown_signing_key}
    end
  end

  defp signing_key(_, _), do: {:error, :invalid_signing_key}

  defp verification_key(keys, key_id) do
    case Map.fetch(keys, key_id) do
      {:ok, secret} when is_binary(secret) -> {:ok, secret}
      _ -> {:error, :unknown_key}
    end
  end

  defp validate_times(parsed, skew) when is_integer(skew) and skew in 0..300 do
    now = System.system_time(:second)

    cond do
      parsed.issued_at > now + skew -> {:error, :issued_in_future}
      parsed.expires_at < now - skew -> {:error, :expired}
      parsed.expires_at <= parsed.issued_at -> {:error, :invalid_lifetime}
      true -> :ok
    end
  end

  defp validate_times(_, _), do: {:error, :invalid_clock_skew}

  defp validate_audience(parsed, expected) when is_binary(expected) do
    if secure_equal(parsed.audience, expected), do: :ok, else: {:error, :audience_mismatch}
  end

  defp validate_audience(_, _), do: {:error, :invalid_audience}

  defp secure_equal(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  rescue
    _ -> false
  end

  defp secure_equal(_, _), do: false
end
