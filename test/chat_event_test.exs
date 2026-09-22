defmodule Wiregrid.ChatEventTest do
  use ExUnit.Case, async: true

  alias Wiregrid.Chat.{Config, Event}

  test "message constructor is bounded and preserves chat metadata" do
    cfg = Config.build!([])
    assert {:ok, event} = Event.message(" hello ", [mentions: ["u1"], nonce: "n1"], cfg)
    assert event.type == :message
    assert event.body == "hello"
    assert event.mentions == ["u1"]
    assert event.nonce == "n1"
  end

  test "chat limits reject oversized input before publication" do
    cfg = Config.build!(max_message_bytes: 4, max_attachment_count: 1)
    assert {:error, :message_too_large} = Event.message("hello", [], cfg)

    assert {:error, {:invalid_or_too_many, :attachments}} =
             Event.message("ok", [attachments: [%{}, %{}]], cfg)
  end

  test "reaction and edit event constructors reject invalid identifiers" do
    cfg = Config.build!([])
    assert {:error, {:invalid, :message_id}} = Event.reaction("", "👍", true, cfg)
    assert {:ok, %{type: :message_edit}} = Event.edit("m1", "new", cfg)
  end
end
