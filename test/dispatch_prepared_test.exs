defmodule Wiregrid.DispatchPreparedTest do
  use Wiregrid.TestCase, async: false

  test "prepared multi-room fanout reuses one event id and honors room membership", %{
    instance: instance
  } do
    assert {:ok, sid} =
             Wiregrid.connect(instance, "room-fanout", self(), delivery_format: :encoded)

    first = {:room, "prepared-one"}
    second = {:room, "prepared-two"}
    assert :ok = Wiregrid.join_room(instance, first, sid)
    assert :ok = Wiregrid.join_room(instance, second, sid)

    event = %{kind: :room_notice, body: String.duplicate("x", 2048)}
    assert {:ok, prepared} = Wiregrid.prepare(instance, event)

    assert {:ok, %{completed: 2, failed: 0, event_id: event_id, results: results}} =
             Wiregrid.publish_rooms_prepared(instance, [first, second, first], prepared)

    assert Enum.all?(results, fn {:ok, result} -> result.event_id == event_id end)

    envelopes = for _ <- 1..2, do: elem(receive_delivery(), 1)
    assert MapSet.new(Enum.map(envelopes, & &1.topic)) == MapSet.new([first, second])

    Enum.each(envelopes, fn envelope ->
      assert {:ok, ^event} = Wiregrid.decode_payload(instance, envelope.payload)
      assert {:ok, _} = ack_delivery(instance, envelope)
    end)

    assert Wiregrid.pending(instance, sid) == 0
  end

  test "prepared direct batches deduplicate users and sessions", %{instance: instance} do
    assert {:ok, sid} =
             Wiregrid.connect(instance, "direct-user", self(), delivery_format: :encoded)

    event = %{kind: :direct_notice}
    assert {:ok, prepared} = Wiregrid.prepare(instance, event)

    assert {:ok, %{sent: 1, gone: 0}} =
             Wiregrid.send_sessions_prepared(instance, [sid, sid], prepared)

    first = elem(receive_delivery(), 1)
    assert first.topic == {:custom, :sessions}
    assert {:ok, ^event} = Wiregrid.decode_payload(instance, first.payload)
    assert {:ok, 0} = ack_delivery(instance, first)

    assert {:ok, %{sent: 1, gone: 0}} =
             Wiregrid.send_users_prepared(instance, ["direct-user", "direct-user"], prepared)

    second = elem(receive_delivery(), 1)
    assert second.topic == {:custom, :users}
    assert {:ok, 0} = ack_delivery(instance, second)
  end

  test "heterogeneous dispatch validates and deduplicates before fanout", %{instance: instance} do
    assert {:ok, sid} = Wiregrid.connect(instance, "dispatch-user", self())
    topic = {:channel, "dispatch"}
    room = {:room, "dispatch"}
    assert :ok = Wiregrid.subscribe(instance, sid, topic)
    assert :ok = Wiregrid.join_room(instance, room, sid)

    targets = [
      {:topic, topic},
      {:topic, topic},
      {:room, room},
      {:user, "dispatch-user"},
      {:session, sid}
    ]

    assert {:ok, result} = Wiregrid.dispatch(instance, targets, %{kind: :mixed})
    assert result.target_count == 4
    assert result.failed_groups == 0
    refute result.partial
    assert match?({:ok, _}, result.groups.topics)
    assert match?({:ok, _}, result.groups.rooms)
    assert match?({:ok, _}, result.groups.users)
    assert match?({:ok, _}, result.groups.sessions)

    envelopes = for _ <- 1..4, do: elem(receive_delivery(), 1)
    assert Enum.all?(envelopes, &(&1.event == %{kind: :mixed}))
    Enum.each(envelopes, fn envelope -> assert {:ok, _} = ack_delivery(instance, envelope) end)
    assert Wiregrid.pending(instance, sid) == 0
  end

  test "heterogeneous dispatch rejects the full call before side effects when a target is invalid",
       %{instance: instance} do
    assert {:ok, sid} = Wiregrid.connect(instance, "dispatch-invalid", self())
    topic = {:channel, "safe"}
    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    assert {:error, :invalid_dispatch_target} =
             Wiregrid.dispatch(instance, [{:topic, topic}, {:wat, "nope"}], %{
               kind: :must_not_send
             })

    refute_receive {:"$wiregrid", _}, 50
    assert Wiregrid.pending(instance, sid) == 0
  end
end
