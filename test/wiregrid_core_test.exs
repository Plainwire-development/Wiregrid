defmodule Wiregrid.CoreTest do
  use Wiregrid.TestCase, async: false

  test "multi-session presence and indexed topic fanout", %{instance: instance} do
    assert {:ok, a1} = Wiregrid.connect(instance, "alice", self(), status: :idle)
    assert {:ok, a2} = Wiregrid.connect(instance, "alice", self(), status: :online)
    assert :ok = Wiregrid.subscribe(instance, a1, {:channel, "general"})
    assert :ok = Wiregrid.subscribe(instance, a2, {:channel, "general"})

    assert %{status: :online, sessions: 2} = Wiregrid.presence(instance, "alice")

    assert {:ok, %{sent: 2, event_id: event_id}} =
             Wiregrid.publish(instance, {:channel, "general"}, %{type: :message, body: "hi"})

    assert Wiregrid.ID.valid?(event_id)

    {_id1, e1} = receive_delivery()
    {_id2, e2} = receive_delivery()
    assert MapSet.new([e1.session_id, e2.session_id]) == MapSet.new([a1, a2])
    assert e1.event == %{type: :message, body: "hi"}
    assert e1.topic == {:channel, "general"}
    assert {:ok, _} = ack_delivery(instance, e1)
    assert {:ok, _} = ack_delivery(instance, e2)
    assert Wiregrid.pending(instance, a1) == 0
    assert Wiregrid.pending(instance, a2) == 0
  end

  test "process death automatically cleans sessions and presence", %{instance: instance} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, sid} = Wiregrid.connect(instance, "owner", owner)
    assert :ok = Wiregrid.subscribe(instance, sid, {:channel, "x"})
    Process.exit(owner, :kill)

    assert eventually(fn -> Wiregrid.stats(instance).sessions == 0 end, 2_000)
    assert %{status: :offline, sessions: 0} = Wiregrid.presence(instance, "owner")
    assert Wiregrid.stats(instance).subscriptions == 0
  end

  test "multiple instances remain isolated", %{instance: first} do
    second = {:isolated, System.unique_integer([:positive])}
    {:ok, _} = Wiregrid.start_instance(second, profile: :small, cluster: false)
    on_exit(fn -> Wiregrid.stop_instance(second) end)

    {:ok, s1} = Wiregrid.connect(first, "same-user", self())
    {:ok, s2} = Wiregrid.connect(second, "same-user", self())
    :ok = Wiregrid.subscribe(first, s1, {:channel, "same"})
    :ok = Wiregrid.subscribe(second, s2, {:channel, "same"})

    {:ok, %{sent: 1}} = Wiregrid.publish(first, {:channel, "same"}, %{from: :first})
    {_delivery, envelope} = receive_delivery()
    assert envelope.instance == first
    assert envelope.session_id == s1
    refute_received {:"$wiregrid", %{instance: ^second}}
    assert {:ok, 0} = ack_delivery(first, envelope)
  end

  test "drain blocks new work but allows cleanup", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "u", self())
    assert :ok = Wiregrid.drain(instance)
    assert {:error, :draining} = Wiregrid.connect(instance, "new", self())
    assert {:error, :draining} = Wiregrid.publish(instance, {:channel, "x"}, %{x: 1})
    assert :not_ready = Wiregrid.readiness(instance)
    assert :ok = Wiregrid.disconnect(instance, sid)
    assert :ok = Wiregrid.await_idle(instance, 1_000)
  end
end
