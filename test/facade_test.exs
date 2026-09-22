defmodule Wiregrid.FacadeTest do
  use Wiregrid.TestCase, async: false

  test "plain-term Erlang facade uses the same runtime", %{instance: instance} do
    {:ok, sid} = :wiregrid_api.connect(instance, "alice", self())
    topic = :wiregrid_api.topic_channel("general")
    assert :ok = :wiregrid_api.subscribe(instance, sid, topic)
    assert {:ok, counts} = :wiregrid_api.publish(instance, topic, %{body: "hello"})
    assert counts.sent == 1
    {_id, envelope} = receive_delivery()
    assert {:ok, 0} = :wiregrid_api.ack(instance, sid, envelope.delivery_id)
  end

  test "plain-term facade exposes batch, query and multi-topic APIs", %{instance: instance} do
    {:ok, sid} = :wiregrid_api.connect(instance, "facade", self())
    one = :wiregrid_api.topic_channel("one")
    two = :wiregrid_api.topic_document("two")
    assert :ok = :wiregrid_api.subscribe(instance, sid, one)
    assert :ok = :wiregrid_api.subscribe(instance, sid, two)

    assert {:ok, result} = :wiregrid_api.publish_topics(instance, [one, two], %{body: "x"})
    assert result.completed == 2
    assert {:ok, [^sid]} = :wiregrid_api.topic_sessions(instance, one)
    assert {:ok, limits} = :wiregrid_api.limits(instance)
    assert limits.profile == :small

    first = elem(receive_delivery(), 1)
    second = elem(receive_delivery(), 1)
    assert {:ok, _} = :wiregrid_api.ack(instance, sid, first.delivery_id)
    assert {:ok, _} = :wiregrid_api.ack(instance, sid, second.delivery_id)
  end

  test "batched consumer groups acknowledgements across the stable facade", %{instance: instance} do
    {:ok, sid} = :wiregrid_api.connect(instance, "batch-consumer", self())
    topic = :wiregrid_api.topic_channel("batch-consumer")
    :ok = :wiregrid_api.subscribe(instance, sid, topic)

    assert {:ok, _} = :wiregrid_api.publish(instance, topic, %{n: 1})
    assert {:ok, _} = :wiregrid_api.publish(instance, topic, %{n: 2})
    {_id1, first} = receive_delivery()
    {_id2, second} = receive_delivery()

    assert {:ok, result} =
             :wiregrid_api.consume_many_deliveries(instance, [first, second], fn _event,
                                                                                 _envelope ->
               :ok
             end)

    assert result.handled == 2
    assert result.acked == 2
    assert result.failed == 0
    assert Wiregrid.pending(instance, sid) == 0
  end

  test "plain-term facade exposes prepared heterogeneous dispatch", %{instance: instance} do
    {:ok, sid} = :wiregrid_api.connect(instance, "dispatch-facade", self())
    topic = :wiregrid_api.topic_channel("dispatch")
    room = :wiregrid_api.topic_room("dispatch")
    assert :ok = :wiregrid_api.subscribe(instance, sid, topic)
    assert :ok = :wiregrid_api.join_room(instance, room, sid)
    assert {:ok, prepared} = :wiregrid_api.prepare(instance, %{kind: :facade_dispatch})

    targets = [
      :wiregrid_api.target_topic(topic),
      :wiregrid_api.target_room(room),
      :wiregrid_api.target_user("dispatch-facade"),
      :wiregrid_api.target_session(sid)
    ]

    assert {:ok, %{target_count: 4, failed_groups: 0}} =
             :wiregrid_api.dispatch_prepared(instance, targets, prepared)

    envelopes = for _ <- 1..4, do: elem(receive_delivery(), 1)

    Enum.each(envelopes, fn envelope ->
      assert {:ok, _} = :wiregrid_api.ack(instance, envelope.session_id, envelope.delivery_id)
    end)

    assert :wiregrid_api.pending(instance, sid) == 0
  end

  test "Gleam FFI exposes typed presence and replay summaries", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "typed-gleam", self(), delivery_format: :term)
    assert :ok = Wiregrid.set_presence(instance, sid, :online, %{device: "test"})

    assert {:ok, {"online", "", 1, metadata, updated_at_ms}} =
             :wiregrid_gleam_ffi.presence_snapshot(instance, "typed-gleam")

    assert metadata == %{device: "test"}
    assert is_integer(updated_at_ms) and updated_at_ms >= 0

    stream = {:channel, "typed-replay"}
    assert :ok = Wiregrid.append_event(instance, stream, "typed-1", %{body: "hello"})

    assert {:ok, {1, 0, true, resume_cursor, next_cursor, nil}} =
             :wiregrid_gleam_ffi.replay_session_typed(instance, sid, stream, [{:limit, 1}])

    assert is_binary(resume_cursor)
    assert is_binary(next_cursor) or is_nil(next_cursor)
    {_id, envelope} = receive_delivery()
    assert {:ok, _} = Wiregrid.ack(instance, sid, envelope.delivery_id)
  end
end
