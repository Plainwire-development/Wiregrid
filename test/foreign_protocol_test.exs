defmodule Wiregrid.ForeignProtocolTest do
  use ExUnit.Case, async: true

  alias Wiregrid.Foreign.Protocol

  test "round trips bounded TLV frames" do
    fields = [{Protocol.field(:topic), "general"}, {Protocol.field(:payload), <<0, 1, 2>>}]
    assert {:ok, encoded} = Protocol.encode(0, Protocol.op(:publish), 42, fields)
    assert {:ok, frame} = Protocol.decode(encoded)
    assert frame.request_id == 42
    assert frame.fields[Protocol.field(:topic)] == "general"
    assert frame.fields[Protocol.field(:payload)] == <<0, 1, 2>>
  end

  test "rejects duplicate fields and unsupported versions" do
    tag = Protocol.field(:topic)

    assert {:error, {:duplicate_field, ^tag}} =
             Protocol.encode(0, Protocol.op(:subscribe), 1, [{tag, "a"}, {tag, "b"}])

    assert {:error, {:unsupported_protocol, 99}} = Protocol.decode(<<99, 0, 1, 0, 0, 0, 1>>)
  end
end
