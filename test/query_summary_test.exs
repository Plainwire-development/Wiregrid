defmodule Wiregrid.QuerySummaryTest do
  use Wiregrid.TestCase, async: false

  test "bounded summary APIs compose authoritative indexes", %{instance: instance} do
    topic = {:channel, "summary"}
    room = {:room, "summary"}

    assert {:ok, sid} =
             Wiregrid.connect(instance, "summary-user", self(), metadata: %{device: "desktop"})

    assert :ok = Wiregrid.subscribe(instance, sid, topic)
    assert :ok = Wiregrid.watch_presence(instance, sid, "summary-target")
    assert :ok = Wiregrid.join_room(instance, room, sid)
    assert :ok = Wiregrid.set_room_metadata(instance, room, sid, %{purpose: "test"})

    assert {:ok, state} = Wiregrid.session_state(instance, sid)
    assert state.session.id == sid
    assert topic in state.subscriptions
    assert room in state.rooms
    assert "summary-target" in state.presence_watches

    assert {:ok, topic_summary} = Wiregrid.topic_info(instance, topic, 10)
    assert topic_summary.subscriber_count == 1
    assert topic_summary.sessions == [sid]
    refute topic_summary.truncated

    assert {:ok, room_summary} = Wiregrid.room_info(instance, room, 10)
    assert room_summary.local_member_count == 1
    assert Enum.any?(room_summary.members, &(&1.session_id == sid))
    assert room_summary.state.metadata == %{purpose: "test"}
    refute room_summary.sample_limit_reached

    assert {:ok, user_summary} = Wiregrid.user_info(instance, "summary-user", 10)
    assert user_summary.session_count == 1
    assert Enum.any?(user_summary.sessions, &(&1.id == sid))
  end
end
