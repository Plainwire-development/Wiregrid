defmodule Wiregrid.ID do
  import Bitwise

  @moduledoc "UUIDv7 identifiers with millisecond time ordering and cryptographic randomness."

  @spec generate() :: binary()
  def generate do
    timestamp = System.system_time(:millisecond) &&& 0xFFFFFFFFFFFF
    <<rand_a::12, rand_b::62, _discard::6>> = :crypto.strong_rand_bytes(10)
    raw = <<timestamp::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    hex = Base.encode16(raw, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end

  @spec valid?(term()) :: boolean()
  def valid?(<<
        a::binary-size(8),
        "-",
        b::binary-size(4),
        "-",
        "7",
        c::binary-size(3),
        "-",
        variant,
        d::binary-size(3),
        "-",
        e::binary-size(12)
      >>)
      when variant in [?8, ?9, ?a, ?b] do
    lowercase_hex?(a) and lowercase_hex?(b) and lowercase_hex?(c) and
      lowercase_hex?(d) and lowercase_hex?(e)
  end

  def valid?(_), do: false

  defp lowercase_hex?(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end
end
