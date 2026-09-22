defmodule Wiregrid.BatchQueryAndFanoutTest do
  use Wiregrid.TestCase, async: false

  test "encoded sessions receive payload without a copied event term", %{instance: instance} do
    assert {:ok, sid} =
             Wiregrid.connect(instance, "encoded-user", self(), delivery_format: :encoded)

    topic = {:channel, "encoded"}
    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    event = %{type: :message, body: String.duplicate("x", 4_096)}
    assert {:ok, %{sent: 1, cluster: :disabled}} = Wiregrid.publish(instance, topic, event)

    {_delivery_id, envelope} = receive_delivery()
    assert envelope.session_id == sid
    assert is_binary(envelope.payload)
    refute Map.has_key?(envelope, :event)
    assert {:ok, ^event} = Wiregrid.decode_payload(instance, envelope.payload)
    assert {:ok, 0} = ack_delivery(instance, envelope)
  end

  test "multi-topic publish encodes once at the public boundary and reports every topic", %{
    instance: instance
  } do
    assert {:ok, sid} = Wiregrid.connect(instance, "multi", self())
    first = {:channel, "one"}
    second = {:document, "two"}
    assert :ok = Wiregrid.subscribe(instance, sid, first)
    assert :ok = Wiregrid.subscribe(instance, sid, second)

    assert {:ok, result} =
             Wiregrid.publish_topics(instance, [first, second, first], %{body: "same"})

    assert result.completed == 2
    assert result.failed == 0
    assert length(result.results) == 2

    assert Enum.all?(result.results, fn {:ok, item} ->
             item.event_id == result.event_id and item.cluster == :disabled
           end)

    {_id1, e1} = receive_delivery()
    {_id2, e2} = receive_delivery()
    assert MapSet.new([e1.topic, e2.topic]) == MapSet.new([first, second])
    assert {:ok, _} = ack_delivery(instance, e1)
    assert {:ok, 0} = ack_delivery(instance, e2)
  end

  test "batch publish and multi-target delivery expose partial-result accounting", %{
    instance: instance
  } do
    assert {:ok, first} = Wiregrid.connect(instance, "first", self())
    assert {:ok, second} = Wiregrid.connect(instance, "second", self())
    topic = {:channel, "batch"}
    assert :ok = Wiregrid.subscribe(instance, first, topic)

    assert {:ok, %{completed: 3, failed: 0, results: results}} =
             Wiregrid.publish_batch(instance, topic, [%{n: 1}, %{n: 2}, %{n: 3}])

    assert length(results) == 3

    envelopes = for _ <- 1..3, do: elem(receive_delivery(), 1)
    Enum.each(envelopes, fn envelope -> assert {:ok, _} = ack_delivery(instance, envelope) end)

    assert {:ok, %{sent: 2, gone: 0}} =
             Wiregrid.send_sessions(instance, [first, second, first], %{kind: :notice})

    d1 = elem(receive_delivery(), 1)
    d2 = elem(receive_delivery(), 1)
    assert MapSet.new([d1.session_id, d2.session_id]) == MapSet.new([first, second])
    assert {:ok, _} = ack_delivery(instance, d1)
    assert {:ok, _} = ack_delivery(instance, d2)
  end

  test "bounded query API sanitizes sessions and follows fanout lifecycle", %{instance: instance} do
    topic = {:channel, "inspect"}

    assert {:ok, sid} =
             Wiregrid.connect_resumable(instance, "viewer", self(), metadata: %{device: "test"})
             |> resumable_session_id()

    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    assert {:ok, public} = Wiregrid.session(instance, sid)
    assert public.id == sid
    assert public.metadata == %{device: "test"}
    refute Map.has_key?(public, :pid)
    refute Map.has_key?(public, :monitor)
    refute Map.has_key?(public, :resume_hash)

    assert {:ok, [^sid]} = Wiregrid.topic_sessions(instance, topic)
    assert {:ok, [^topic]} = Wiregrid.subscriptions(instance, sid)
    assert Wiregrid.subscribed?(instance, sid, topic)

    assert {:ok, limits} = Wiregrid.limits(instance)
    assert limits.profile == :small
    assert limits.fanout_buckets == 32
    refute Map.has_key?(limits, :storage)
    refute Map.has_key?(limits, :webhooks)

    assert :ok = Wiregrid.unsubscribe(instance, sid, topic)
    assert {:ok, []} = Wiregrid.topic_sessions(instance, topic)
    refute Wiregrid.subscribed?(instance, sid, topic)
  end

  test "instance child spec is suitable for an ordinary OTP supervision tree" do
    spec = Wiregrid.instance_child_spec(:embedded, profile: :small)
    assert spec.id == {Wiregrid.Instance, :embedded}
    assert spec.type == :supervisor

    assert spec.start ==
             {Wiregrid.Instance, :start_link, [[instance: :embedded, options: [profile: :small]]]}
  end

  defp resumable_session_id({:ok, sid, _token}), do: {:ok, sid}
  defp resumable_session_id(other), do: other

  test "pressure snapshot reports configured headroom without exposing internals", %{
    instance: instance
  } do
    assert {:ok, pressure} = Wiregrid.pressure(instance)
    assert pressure.sessions.used == 0
    assert pressure.sessions.limit > 0
    assert pressure.sessions.headroom == pressure.sessions.limit
    assert pressure.sessions.ratio == 0.0
    refute Map.has_key?(pressure.sessions, :table)
  end
end
