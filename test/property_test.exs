defmodule Wiregrid.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "bounded SafeTerm round-trips common portable values" do
    portable =
      one_of([
        integer(),
        binary(),
        list_of(integer(), max_length: 32),
        map_of(binary(), integer(), max_length: 16)
      ])

    check all(value <- portable, max_runs: 200) do
      assert {:ok, encoded} = Wiregrid.SafeTerm.encode(value, 1_048_576)
      assert byte_size(encoded) <= 1_048_576
      assert {:ok, ^value} = Wiregrid.SafeTerm.decode(encoded, 1_048_576)
    end
  end

  property "generated UUIDv7 identifiers pass strict canonical validation" do
    check all(_seed <- integer(), max_runs: 250) do
      id = Wiregrid.ID.generate()
      assert byte_size(id) == 36
      assert Wiregrid.ID.valid?(id)
    end
  end

  test "UUID validation rejects non-canonical lookalikes" do
    id = Wiregrid.ID.generate()
    assert Wiregrid.ID.valid?(id)
    refute Wiregrid.ID.valid?(String.upcase(id))
    refute Wiregrid.ID.valid?(String.replace(id, "-", "_"))

    <<prefix::binary-size(35), _::binary-size(1)>> = id
    refute Wiregrid.ID.valid?(prefix <> "g")
  end
end
