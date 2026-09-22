defmodule Wiregrid.ControlPlaneInvariantsTest do
  use Wiregrid.TestCase, async: false

  test "owner death removes subscriptions, watches and room edges together", %{instance: instance} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, sid} = Wiregrid.connect(instance, "owner", owner)
    topic = {:channel, "cleanup"}
    room = {:room, "cleanup"}

    assert :ok = Wiregrid.subscribe(instance, sid, topic)
    assert :ok = Wiregrid.watch_presence(instance, sid, "watched")
    assert :ok = Wiregrid.join_room(instance, room, sid)
    assert {:ok, 1} = Wiregrid.topic_subscriber_count(instance, topic)
    assert {:ok, 1} = Wiregrid.presence_watcher_count(instance, "watched")
    assert {:ok, 1} = Wiregrid.room_member_count(instance, room)

    Process.exit(owner, :kill)

    assert eventually(fn -> Wiregrid.stats(instance).sessions == 0 end, 2_000)
    assert {:ok, 0} = Wiregrid.topic_subscriber_count(instance, topic)
    assert {:ok, 0} = Wiregrid.presence_watcher_count(instance, "watched")
    assert {:ok, 0} = Wiregrid.room_member_count(instance, room)
    assert {:ok, []} = Wiregrid.topic_sessions(instance, topic)
  end

  test "refreshing room ttl prevents an older expiry from deleting the room", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "ttl-owner", self())
    room = {:room, "refresh"}
    assert :ok = Wiregrid.join_room(instance, room, sid)
    assert :ok = Wiregrid.set_room_ttl(instance, room, sid, 80)
    Process.sleep(40)
    assert :ok = Wiregrid.set_room_ttl(instance, room, sid, 250)

    Process.sleep(80)
    assert {:ok, 1} = Wiregrid.room_member_count(instance, room)
    assert Wiregrid.room_member?(instance, room, sid)
    assert eventually(fn -> Wiregrid.room_members(instance, room) == [] end, 1_000)
  end

  test "recoverable resume failure restores the one-time credential" do
    instance = {:resume_rollback, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        cluster: false,
        max_sessions: 1,
        max_sessions_per_user: 1,
        resume_ttl_ms: 5_000
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)

    {:ok, old_sid, token} = Wiregrid.connect_resumable(instance, "alice", self())
    assert :ok = Wiregrid.disconnect(instance, old_sid)
    {:ok, blocker} = Wiregrid.connect(instance, "blocker", self())

    assert {:error, :session_capacity} = Wiregrid.resume_session(instance, "alice", self(), token)
    assert :ok = Wiregrid.disconnect(instance, blocker)
    assert {:ok, resumed} = Wiregrid.resume_session(instance, "alice", self(), token)
    assert resumed.session_id != old_sid
    assert resumed.resume_token != token

    assert {:error, :invalid_resume_token} =
             Wiregrid.resume_session(instance, "alice", self(), token)
  end

  test "one owner pid cannot multiply mailbox pressure through unlimited sessions" do
    instance = {:owner_cap, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        cluster: false,
        max_sessions_per_owner: 1,
        max_sessions_per_user: 8
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)

    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert {:ok, sid} = Wiregrid.connect(instance, "alice", owner)
    assert {:error, :owner_session_capacity} = Wiregrid.connect(instance, "bob", owner)
    assert :ok = Wiregrid.disconnect(instance, sid)
    assert {:ok, _sid2} = Wiregrid.connect(instance, "bob", owner)
  end
end
