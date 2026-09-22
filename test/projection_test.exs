defmodule Wiregrid.ProjectionTest do
  use Wiregrid.TestCase, async: true

  test "projection commits once before grouped ACK", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "projection-user", self())
    topic = {:channel, "projection"}
    :ok = Wiregrid.subscribe(instance, sid, topic)

    for n <- 1..3 do
      assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: n})
    end

    envelopes =
      for _ <- 1..3 do
        {_delivery_id, envelope} = receive_delivery()
        envelope
      end

    parent = self()

    reducer = fn %{n: n}, _envelope, acc -> {:ok, acc + n} end

    commit = fn value, summary ->
      send(parent, {:projection_commit, value, summary, Wiregrid.pending(instance, sid)})
      {:ok, :stored}
    end

    assert {:ok, result} = Wiregrid.consume_projection(instance, envelopes, 0, reducer, commit)
    assert result.value == 6
    assert result.commit == :stored
    assert result.acks.acked == 3
    assert result.summary == %{handled: 3, dropped: 0, deliveries: 3}

    # Commit observes reservations still outstanding. They are released only
    # after the application state has committed successfully.
    assert_receive {:projection_commit, 6, %{deliveries: 3}, 3}
    assert Wiregrid.pending(instance, sid) == 0
  end

  test "projection failure leaves the whole batch reserved", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "projection-failure", self())
    topic = {:channel, "projection-failure"}
    :ok = Wiregrid.subscribe(instance, sid, topic)

    for n <- 1..2 do
      assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: n})
    end

    envelopes =
      for _ <- 1..2 do
        {_delivery_id, envelope} = receive_delivery()
        envelope
      end

    reducer = fn
      %{n: 1}, _envelope, acc -> {:ok, acc + 1}
      %{n: 2}, _envelope, _acc -> {:error, :reject}
    end

    commit = fn _value, _summary -> flunk("commit must not run after reducer failure") end

    assert {:error, %{phase: :reduce, reason: :reject}} =
             Wiregrid.consume_projection(instance, envelopes, 0, reducer, commit)

    assert Wiregrid.pending(instance, sid) == 2

    for envelope <- envelopes do
      assert {:ok, _} = ack_delivery(instance, envelope)
    end
  end

  test "projection commit failure does not ACK", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "projection-commit-failure", self())
    topic = {:channel, "projection-commit-failure"}
    :ok = Wiregrid.subscribe(instance, sid, topic)
    assert {:ok, %{sent: 1}} = Wiregrid.publish(instance, topic, %{n: 1})
    {_delivery_id, envelope} = receive_delivery()

    reducer = fn _event, _envelope, acc -> {:ok, acc + 1} end
    commit = fn _value, _summary -> {:error, :storage_down} end

    assert {:error, %{phase: :commit, reason: :storage_down}} =
             Wiregrid.consume_projection(instance, [envelope], 0, reducer, commit)

    assert Wiregrid.pending(instance, sid) == 1
    assert {:ok, 0} = ack_delivery(instance, envelope)
  end
end
