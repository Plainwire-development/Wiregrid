defmodule Wiregrid.SafeTermTest do
  use ExUnit.Case, async: true

  test "safe round trip is bounded" do
    term = %{event: "hello", count: 3}
    assert {:ok, encoded} = Wiregrid.SafeTerm.encode(term, 1_024)
    assert {:ok, ^term} = Wiregrid.SafeTerm.decode(encoded, 1_024)
    assert {:error, :term_too_large} = Wiregrid.SafeTerm.encode(String.duplicate("x", 2_000), 32)
  end

  test "compressed ETF is rejected before decoding" do
    compressed = :erlang.term_to_binary(%{large: String.duplicate("x", 10_000)}, compressed: 9)
    assert <<131, 80, _::binary>> = compressed
    assert {:error, :compressed_term_rejected} = Wiregrid.SafeTerm.decode(compressed, 50_000)
  end
end
