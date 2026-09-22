defmodule Wiregrid.RecoveryPreparedAndBindingTest do
  use Wiregrid.TestCase, async: false

  test "single-call lifecycle batches and O(1) counters stay coherent", %{instance: instance} do
    assert {:ok, sid} = Wiregrid.connect(instance, "batch-user", self())
    topics = [{:channel, "a"}, {:channel, "b"}, {:document, "c"}]

    assert {:ok, %{completed: 3, failed: 0}} = Wiregrid.subscribe_many(instance, sid, topics)

    Enum.each(topics, fn topic ->
      assert {:ok, 1} = Wiregrid.topic_subscriber_count(instance, topic)
    end)

    assert {:ok, 1} = Wiregrid.user_session_count(instance, "batch-user")

    assert {:ok, %{completed: 2, failed: 0}} =
             Wiregrid.watch_presence_many(instance, sid, ["u1", "u2"])

    assert {:ok, 1} = Wiregrid.presence_watcher_count(instance, "u1")

    rooms = [{:room, "one"}, {:room, "two"}]
    assert {:ok, %{completed: 2, failed: 0}} = Wiregrid.join_rooms(instance, rooms, sid)
    assert {:ok, 1} = Wiregrid.room_member_count(instance, hd(rooms))

    assert :ok = Wiregrid.set_session_metadata(instance, sid, %{device: "desktop"})
    assert {:ok, %{metadata: %{device: "desktop"}}} = Wiregrid.session(instance, sid)

    assert {:ok, %{completed: 3, failed: 0}} = Wiregrid.unsubscribe_many(instance, sid, topics)

    assert {:ok, %{completed: 2, failed: 0}} =
             Wiregrid.unwatch_presence_many(instance, sid, ["u1", "u2"])

    assert {:ok, %{completed: 2, failed: 0}} = Wiregrid.leave_rooms(instance, rooms, sid)

    Enum.each(topics, fn topic ->
      assert {:ok, 0} = Wiregrid.topic_subscriber_count(instance, topic)
    end)

    assert {:ok, 0} = Wiregrid.presence_watcher_count(instance, "u1")
    assert {:ok, 0} = Wiregrid.room_member_count(instance, hd(rooms))
  end

  test "prepared events reuse encoded payload but cannot cross codec instances", %{
    instance: instance
  } do
    topic = {:channel, "prepared"}

    assert {:ok, sid} =
             Wiregrid.connect(instance, "prepared-user", self(), delivery_format: :encoded)

    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    event = %{kind: :notice, body: String.duplicate("x", 1024)}
    assert {:ok, prepared} = Wiregrid.prepare(instance, event)
    assert {:ok, %{sent: 1}} = Wiregrid.publish_prepared(instance, topic, prepared)

    {_delivery_id, envelope} = receive_delivery()
    assert {:ok, ^event} = Wiregrid.decode_payload(instance, envelope.payload)
    assert {:ok, 0} = ack_delivery(instance, envelope)

    {:wiregrid_prepared_v2, _codec, _event, _payload, mac} = prepared
    forged = {:wiregrid_prepared_v2, __MODULE__, event, envelope.payload, mac}
    assert {:error, :prepared_event_mismatch} = Wiregrid.Prepared.unpack(instance, forged)
  end

  test "consumer helper acks only successful handling and ack_many is idempotent", %{
    instance: instance
  } do
    topic = {:channel, "consumer"}
    assert {:ok, sid} = Wiregrid.connect(instance, "consumer-user", self())
    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: 1})
    {_id1, first} = receive_delivery()

    assert {:ok, 0} =
             Wiregrid.Consumer.consume(instance, first, fn event, _ ->
               if event.n == 1, do: :ok
             end)

    assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: 2})
    assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: 3})
    {id2, _second} = receive_delivery()
    {id3, _third} = receive_delivery()

    assert {:ok, %{acked: 2, unknown: [], pending: 0}} =
             Wiregrid.ack_many(instance, sid, [id2, id3])

    assert {:ok, %{acked: 0, unknown: unknown, pending: 0}} =
             Wiregrid.ack_many(instance, sid, [id2, id3])

    assert MapSet.new(unknown) == MapSet.new([id2, id3])
  end

  test "Runtime restart reconstructs derived lifecycle state from authoritative ETS edges", %{
    instance: instance
  } do
    topic = {:channel, "recover"}
    room = {:room, "recover"}
    assert {:ok, sid} = Wiregrid.connect(instance, "restart-user", self())
    assert :ok = Wiregrid.subscribe(instance, sid, topic)
    assert :ok = Wiregrid.watch_presence(instance, sid, "watched")
    assert :ok = Wiregrid.join_room(instance, room, sid)

    [{runtime, _}] = Registry.lookup(Wiregrid.ProcessRegistry, {:runtime, instance})
    Process.exit(runtime, :kill)

    assert eventually(
             fn ->
               case Registry.lookup(Wiregrid.ProcessRegistry, {:runtime, instance}) do
                 [{replacement, _}] -> replacement != runtime and Wiregrid.ready?(instance)
                 _ -> false
               end
             end,
             2_000
           )

    assert Wiregrid.subscribed?(instance, sid, topic)
    assert Wiregrid.room_member?(instance, room, sid)
    assert {:ok, ["watched"]} = Wiregrid.presence_watches(instance, sid)
    assert {:ok, 1} = Wiregrid.topic_subscriber_count(instance, topic)
    assert {:ok, 1} = Wiregrid.room_member_count(instance, room)
    assert {:ok, 1} = Wiregrid.presence_watcher_count(instance, "watched")
    assert {:ok, 1} = Wiregrid.user_session_count(instance, "restart-user")
  end
end
