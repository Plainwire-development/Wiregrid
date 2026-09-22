defmodule Wiregrid.Storage.Cursor do
  @moduledoc false
  @version 1

  def encode(inserted_at_ms, id)
      when is_integer(inserted_at_ms) and inserted_at_ms >= 0 and is_binary(id) do
    payload = <<@version, inserted_at_ms::unsigned-64, byte_size(id)::unsigned-16, id::binary>>
    Base.url_encode64(payload, padding: false)
  end

  def decode(nil, _max_id_bytes), do: {:ok, nil}

  def decode(cursor, max_id_bytes) when is_binary(cursor) and byte_size(cursor) <= 1_024 do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         <<@version, inserted_at_ms::unsigned-64, id_len::unsigned-16, rest::binary>> <- raw,
         true <- id_len > 0 and id_len <= max_id_bytes and byte_size(rest) == id_len,
         <<id::binary-size(^id_len)>> <- rest do
      {:ok, {inserted_at_ms, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_, _), do: {:error, :invalid_cursor}
end
