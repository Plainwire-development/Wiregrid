defmodule Wiregrid.IDTest do
  use ExUnit.Case, async: true

  test "generated identifiers are UUIDv7-shaped and unique under concurrency" do
    ids =
      1..2_000
      |> Task.async_stream(fn _ -> Wiregrid.ID.generate() end,
        max_concurrency: 64,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert Enum.all?(ids, &Wiregrid.ID.valid?/1)
    assert length(Enum.uniq(ids)) == length(ids)
    assert Enum.all?(ids, &(byte_size(&1) == 36))
  end
end
