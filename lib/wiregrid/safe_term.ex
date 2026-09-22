defmodule Wiregrid.SafeTerm do
  @moduledoc false

  # COMPRESSED_EXT in the external term format. Rejecting it before decoding
  # prevents a tiny untrusted frame from expanding into a very large heap term.
  @compressed_tag 80

  def encode(term, max_bytes) do
    with {:ok, size} <- Wiregrid.Validation.safe_size(term),
         true <- size <= max_bytes do
      try do
        binary = :erlang.term_to_binary(term, [:deterministic])
        if byte_size(binary) <= max_bytes, do: {:ok, binary}, else: {:error, :term_too_large}
      rescue
        _ -> {:error, :encode_failed}
      end
    else
      false -> {:error, :term_too_large}
      {:error, _} = error -> error
    end
  end

  def decode(binary, max_bytes) when is_binary(binary) and byte_size(binary) <= max_bytes do
    if compressed_external_term?(binary) do
      {:error, :compressed_term_rejected}
    else
      try do
        {:ok, :erlang.binary_to_term(binary, [:safe])}
      rescue
        _ -> {:error, :decode_failed}
      catch
        _, _ -> {:error, :decode_failed}
      end
    end
  end

  def decode(binary, _max_bytes) when is_binary(binary), do: {:error, :term_too_large}
  def decode(_, _), do: {:error, :invalid_binary}

  defp compressed_external_term?(<<131, @compressed_tag, _rest::binary>>), do: true
  defp compressed_external_term?(_), do: false
end
