defmodule Wiregrid.BackpressureTest do
  use Wiregrid.TestCase, async: false

  @moduletag wiregrid_opts: [soft_queue: 2, hard_queue: 4, max_delivery_reservations: 32]

  test "ephemeral traffic sheds above the soft threshold while durable traffic continues", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "slow", self())
    :ok = Wiregrid.subscribe(instance, sid, {:channel, "pressure"})

    assert {:ok, %{sent: 1}} =
             Wiregrid.publish(instance, {:channel, "pressure"}, %{n: 1}, class: :durable)

    assert {:ok, %{sent: 1}} =
             Wiregrid.publish(instance, {:channel, "pressure"}, %{n: 2}, class: :durable)

    assert Wiregrid.pending(instance, sid) == 2

    assert {:ok, %{dropped: 1, sent: 0}} =
             Wiregrid.publish(instance, {:channel, "pressure"}, %{type: :typing},
               class: :ephemeral
             )

    assert Wiregrid.pending(instance, sid) == 2
    {_id1, e1} = receive_delivery()
    {_id2, e2} = receive_delivery()
    assert {:ok, _} = ack_delivery(instance, e1)
    assert {:ok, 0} = ack_delivery(instance, e2)
  end

  test "duplicate and mismatched acknowledgements cannot release reservations", %{
    instance: instance
  } do
    {:ok, first} = Wiregrid.connect(instance, "first", self())
    {:ok, second} = Wiregrid.connect(instance, "second", self())
    :ok = Wiregrid.subscribe(instance, first, {:channel, "acks"})

    {:ok, %{sent: 1}} = Wiregrid.publish(instance, {:channel, "acks"}, %{n: 1})
    {delivery_id, envelope} = receive_delivery()
    assert {:error, :unknown_delivery} = Wiregrid.ack(instance, second, delivery_id)
    assert Wiregrid.pending(instance, first) == 1
    assert {:ok, 0} = ack_delivery(instance, envelope)
    assert {:error, :unknown_delivery} = Wiregrid.ack(instance, first, delivery_id)
  end

  test "request/reply correlation stays in the delivery envelope", %{instance: instance} do
    {:ok, requester} = Wiregrid.connect(instance, "requester", self())
    {:ok, target} = Wiregrid.connect(instance, "target", self())

    assert {:ok, %{request_id: request_id, delivery: :sent}} =
             Wiregrid.request_session(instance, requester, target, %{op: "ping"})

    {_id, request_envelope} = receive_delivery()
    assert request_envelope.session_id == target

    assert {:ok, %{kind: :request, request_id: ^request_id, reply_to_session: ^requester}} =
             Wiregrid.request_context(request_envelope)

    assert {:ok, %{request_id: ^request_id, delivery: :sent}} =
             Wiregrid.reply(instance, target, request_envelope, %{op: "pong"})

    {_id, reply_envelope} = receive_delivery()
    assert reply_envelope.session_id == requester

    assert {:ok, %{kind: :reply, request_id: ^request_id}} =
             Wiregrid.request_context(reply_envelope)

    assert {:ok, _} = Wiregrid.ack(instance, target, request_envelope.delivery_id)
    assert {:ok, _} = Wiregrid.ack(instance, requester, reply_envelope.delivery_id)
  end

  test "request reply rejects a forged replier session", %{instance: instance} do
    {:ok, requester} = Wiregrid.connect(instance, "requester-2", self())
    {:ok, target} = Wiregrid.connect(instance, "target-2", self())
    {:ok, attacker} = Wiregrid.connect(instance, "attacker", self())

    assert {:ok, %{delivery: :sent}} =
             Wiregrid.request_session(instance, requester, target, :ping)

    {_id, request_envelope} = receive_delivery()

    assert {:error, :invalid_request_envelope} =
             Wiregrid.reply(instance, attacker, request_envelope, :pong)

    assert {:ok, _} = Wiregrid.ack(instance, target, request_envelope.delivery_id)
  end
end
