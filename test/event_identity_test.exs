defmodule Wiregrid.EventIdentityTest do
  use Wiregrid.TestCase, async: false

  alias Wiregrid.Transport.Protocol.JSON

  @tag wiregrid_opts: [max_metadata_bytes: 8]
  test "event identity does not consume the application's metadata limit", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "ada", self())
    topic = {:channel, "general"}
    :ok = Wiregrid.subscribe(instance, sid, topic)
    assert {:ok, %{event_id: id, sent: 1}} = Wiregrid.publish(instance, topic, :notice)
    {_, envelope} = receive_delivery()
    assert envelope.event_id == id
    assert {:ok, _} = ack_delivery(instance, envelope)

    assert {:ok, %{event_id: direct_id, sent: 1}} =
             Wiregrid.send_users(instance, ["ada"], :notice)

    {_, direct} = receive_delivery()
    assert direct.event_id == direct_id
    assert {:ok, _} = ack_delivery(instance, direct)
  end

  test "event ids do not replace application delivery context", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "ada", self())
    event = :notice
    {:ok, payload} = Wiregrid.Codec.encode(Wiregrid.Tables.get(instance).config, event)

    assert :sent =
             Wiregrid.Delivery.send_session(instance, sid, :topic, payload, event, :durable,
               event_id: "server-id",
               delivery_context: %{event_id: "application-value"}
             )

    {_, envelope} = receive_delivery()
    assert envelope.event_id == "server-id"
    assert envelope.context.event_id == "application-value"
    assert {:ok, _} = ack_delivery(instance, envelope)
  end

  test "live, prepared, replay and browser deliveries keep their storage identity", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "ada", self(), delivery_format: :term)
    topic = {:channel, "general"}
    :ok = Wiregrid.subscribe(instance, sid, topic)
    event = %{type: :message, body: "hello"}
    {:ok, prepared} = Wiregrid.prepare(instance, event)

    for publish <- [
          &Wiregrid.publish(instance, topic, event, &1),
          &Wiregrid.publish_prepared(instance, topic, prepared, &1)
        ] do
      assert {:ok, %{event_id: id}} = publish.(persist: true)
      {_, envelope} = receive_delivery()
      assert envelope.event_id == id
      assert {:ok, %{id: ^id}} = Wiregrid.Storage.get(instance, topic, id)
      assert {:ok, json} = JSON.encode({:event, envelope})
      assert {:ok, %{"event_id" => ^id}} = Wiregrid.Foreign.JSON.decode(json)
      assert {:ok, _} = ack_delivery(instance, envelope)
    end

    assert {:ok, %{delivered: 2}} = Wiregrid.replay_session(instance, sid, topic)

    for _ <- 1..2 do
      {_, envelope} = receive_delivery()
      assert envelope.event_id == envelope.context.storage_id
      assert {:ok, _} = ack_delivery(instance, envelope)
    end
  end

  test "batch, room, direct user and prepared user deliveries expose their event id", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "ada", self())
    topic = {:channel, "general"}
    :ok = Wiregrid.subscribe(instance, sid, topic)
    assert {:ok, %{results: results}} = Wiregrid.publish_batch(instance, topic, [:first, :second])

    for {:ok, result} <- results do
      {_, envelope} = receive_delivery()
      assert envelope.event_id == result.event_id
      assert {:ok, _} = ack_delivery(instance, envelope)
    end

    :ok = Wiregrid.join_room(instance, "lobby", sid)
    {:ok, prepared} = Wiregrid.prepare(instance, :notice)

    for publish <- [
          fn -> Wiregrid.publish_room(instance, "lobby", :notice) end,
          fn -> Wiregrid.send_user(instance, "ada", :notice) end,
          fn -> Wiregrid.send_user_prepared(instance, "ada", prepared) end,
          fn -> Wiregrid.send_users(instance, ["ada"], :notice) end,
          fn -> Wiregrid.send_users_prepared(instance, ["ada"], prepared) end
        ] do
      assert {:ok, %{event_id: id}} = publish.()
      {_, envelope} = receive_delivery()
      assert envelope.event_id == id
      assert {:ok, _} = ack_delivery(instance, envelope)
    end
  end
end
