defmodule Wiregrid.ChatFacadeTest do
  use ExUnit.Case, async: false

  defmodule TestChat do
    use Wiregrid.Chat,
      instance: {:chat_facade, __MODULE__},
      options: [profile: :small, cluster: false]
  end

  setup_all do
    start_supervised!(TestChat)
    :ok
  end

  test "generated chat module connects, joins, publishes and acknowledges" do
    {:ok, alice} = TestChat.connect("alice", self())
    :ok = TestChat.join(alice, "general")

    {:ok, %{event_id: event_id}} = TestChat.say(alice, "general", "hello")
    assert is_binary(event_id)

    assert_receive {:"$wiregrid", envelope}, 1_000
    assert envelope.topic == {:channel, "general"}
    assert envelope.event.type == :message
    assert envelope.event.body == "hello"
    assert {:ok, _} = TestChat.ack(envelope)
  end

  test "message options and delivery options stay separated and persist" do
    {:ok, alice} = TestChat.connect("alice-rich", self())
    :ok = TestChat.join(alice, "rich")

    attachment = %{id: "a1", name: "photo.png", size: 123}

    {:ok, %{event_id: event_id}} =
      TestChat.say(alice, "rich", "with attachment",
        attachments: [attachment],
        mentions: ["bob"],
        event_id: "evt-rich-1",
        meta: %{source: "test"}
      )

    assert event_id == "evt-rich-1"
    assert_receive {:"$wiregrid", envelope}, 1_000
    assert envelope.event.attachments == [attachment]
    assert envelope.event.mentions == ["bob"]

    assert {:ok, rows, _cursor} = TestChat.history("rich", nil, 10)

    assert Enum.any?(rows, fn row ->
             row.id == "evt-rich-1" and row.event.body == "with attachment"
           end)
  end

  test "direct messages are persisted to the recipient inbox stream" do
    {:ok, alice} = TestChat.connect("alice-dm", self())
    {:ok, _bob} = TestChat.connect("bob-dm", self())

    assert {:ok, %{event_id: "dm-1"}} =
             TestChat.whisper(alice, "bob-dm", "private hello", event_id: "dm-1")

    assert {:ok, rows, _cursor} = TestChat.inbox_history("bob-dm", nil, 10)
    assert Enum.any?(rows, fn row -> row.id == "dm-1" and row.event.body == "private hello" end)
  end

  test "unknown or duplicate chat options are rejected" do
    {:ok, alice} = TestChat.connect("alice-options", self())
    assert {:error, :invalid_chat_options} = TestChat.say(alice, "general", "x", made_up: true)

    assert {:error, :invalid_chat_options} =
             TestChat.say(alice, "general", "x", event_id: "a", event_id: "b")
  end

  test "typing is ephemeral and excludes the sender" do
    {:ok, alice} = TestChat.connect("alice-typing", self())
    :ok = TestChat.join(alice, "typing")
    assert {:ok, %{sent: 0, excluded: 1}} = TestChat.typing(alice, "typing", true)
    refute_receive {:"$wiregrid", _}, 50
  end

  test "child spec keeps stable instance identity" do
    spec = TestChat.child_spec([])
    assert spec.type == :supervisor
    assert TestChat.instance() == {:chat_facade, TestChat}
  end
end
