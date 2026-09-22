defmodule Wiregrid.ActorAPITest do
  use Wiregrid.TestCase, async: true

  alias Wiregrid.Actor

  test "actor binds authenticated operations to its live session", %{instance: instance} do
    {:ok, actor} = Wiregrid.connect_actor(instance, "alice", self())
    assert %Actor{user_id: "alice"} = actor

    topic = {:channel, "actor-room"}
    assert :ok = Actor.subscribe(actor, topic)

    assert {:ok, result} = Actor.publish(actor, topic, %{kind: "message", body: "hello"})
    assert is_binary(result.event_id)

    {_delivery_id, envelope} = receive_delivery()
    assert envelope.session_id == actor.session_id
    assert envelope.event == %{kind: "message", body: "hello"}
    assert {:ok, 0} = Actor.ack(actor, envelope.delivery_id)

    assert {:error, :actor_session_override} =
             Actor.publish(actor, topic, %{body: "spoof"}, session_id: "someone-else")
  end

  test "actor creation verifies an existing live session", %{instance: instance} do
    assert {:error, :unknown_session} = Wiregrid.actor(instance, "missing")

    {:ok, session_id} = Wiregrid.connect(instance, "alice", self())

    assert {:ok, %Actor{session_id: ^session_id, user_id: "alice"}} =
             Wiregrid.actor(instance, session_id)

    assert :ok = Wiregrid.disconnect(instance, session_id)
    assert {:error, :unknown_session} = Wiregrid.actor(instance, session_id)
  end

  test "resumable actor rotates credentials and preserves the authenticated identity", %{
    instance: instance
  } do
    {:ok, actor, token} = Wiregrid.connect_resumable_actor(instance, "alice", self())
    topic = {:channel, "resume-actor"}
    assert :ok = Actor.subscribe(actor, topic)
    assert :ok = Actor.disconnect(actor, :network_lost)

    {:ok, resumed, next_token, restored} = Wiregrid.resume_actor(instance, "alice", self(), token)
    assert resumed.user_id == "alice"
    assert resumed.session_id != actor.session_id
    assert is_binary(next_token)
    assert next_token != token
    assert is_map(restored)
    assert Wiregrid.subscribed?(instance, resumed.session_id, topic)

    assert {:error, _} = Wiregrid.resume_actor(instance, "alice", self(), token)
  end
end
