defmodule Wiregrid.ResumeAndRoomsTest do
  use Wiregrid.TestCase, async: false

  @moduletag wiregrid_opts: [resume_ttl_ms: 5_000, reconnect_grace_ms: 5_000]

  test "resumable sessions rotate one-time credentials and restore state", %{instance: instance} do
    assert {:ok, old_sid, token} =
             Wiregrid.connect_resumable(instance, "alice", self(), status: :idle)

    :ok = Wiregrid.subscribe(instance, old_sid, {:channel, "general"})
    :ok = Wiregrid.watch_presence(instance, old_sid, "bob")
    :ok = Wiregrid.join_room(instance, {:room, "call"}, old_sid)
    :ok = Wiregrid.disconnect(instance, old_sid, :transport_closed)

    assert {:error, :resume_not_allowed} =
             Wiregrid.resume_session(instance, "mallory", self(), token)

    assert {:ok, resumed} = Wiregrid.resume_session(instance, "alice", self(), token)
    assert resumed.session_id != old_sid
    assert is_binary(resumed.resume_token)
    assert resumed.resume_token != token
    assert resumed.restored.subscriptions.restored == 1
    assert resumed.restored.presence_watches.restored == 1
    assert resumed.restored.rooms.restored == 1

    assert {:error, :invalid_resume_token} =
             Wiregrid.resume_session(instance, "alice", self(), token)
  end

  test "room reconnect grace is session-scoped and cannot cross users", %{instance: instance} do
    {:ok, old_sid} = Wiregrid.connect(instance, "alice", self())
    :ok = Wiregrid.join_room(instance, {:room, "call"}, old_sid)
    :ok = Wiregrid.disconnect(instance, old_sid)

    {:ok, bob_sid} = Wiregrid.connect(instance, "bob", self())

    assert {:error, :resume_not_allowed} =
             Wiregrid.resume_room(instance, {:room, "call"}, old_sid, bob_sid)

    {:ok, alice_sid} = Wiregrid.connect(instance, "alice", self())
    assert :ok = Wiregrid.resume_room(instance, {:room, "call"}, old_sid, alice_sid)

    assert Enum.any?(
             Wiregrid.room_members(instance, {:room, "call"}),
             &(&1.session_id == alice_sid)
           )
  end

  test "room metadata and bounded TTL are member-authorized", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())
    room = {:room, "ephemeral"}
    assert :ok = Wiregrid.join_room(instance, room, sid)
    assert :ok = Wiregrid.set_room_metadata(instance, room, sid, %{purpose: "call"})
    assert {:ok, %{metadata: %{purpose: "call"}}} = Wiregrid.room_metadata(instance, room)
    assert :ok = Wiregrid.set_room_ttl(instance, room, sid, 50)
    assert eventually(fn -> Wiregrid.room_members(instance, room) == [] end, 1_500)
  end
end
