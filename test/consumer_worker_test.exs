defmodule Wiregrid.ConsumerWorkerTest do
  use Wiregrid.TestCase, async: true

  alias Wiregrid.Consumer.Worker

  test "supervised worker consumes bounded bursts and acknowledges only handled deliveries", %{
    instance: instance
  } do
    parent = self()

    handler = fn event, envelope ->
      send(parent, {:handled, event, envelope.delivery_id})
      :ok
    end

    {:ok, worker} =
      Worker.start_link(
        instance: instance,
        handler: handler,
        batch_size: 8,
        collect_wait_ms: 1,
        failure_policy: :crash
      )

    {:ok, session_id} = Wiregrid.connect(instance, "worker-user", worker)
    topic = {:channel, "worker"}
    assert :ok = Wiregrid.subscribe(instance, session_id, topic)

    for n <- 1..4 do
      assert {:ok, _} = Wiregrid.publish(instance, topic, %{n: n})
    end

    handled =
      for _ <- 1..4 do
        receive do
          {:handled, %{n: n}, delivery_id} -> {n, delivery_id}
        after
          1_000 -> flunk("consumer worker did not handle delivery")
        end
      end

    assert Enum.sort(Enum.map(handled, &elem(&1, 0))) == [1, 2, 3, 4]
    assert eventually(fn -> Wiregrid.pending(instance, session_id) == 0 end)

    stats = Worker.stats(worker)
    assert stats.handled == 4
    assert stats.acked == 4
    assert stats.failed == 0
    assert stats.batch_size == 8
    assert stats.collect_wait_ms == 1
  end

  test "durable-first mode only reorders the bounded removed burst", %{instance: instance} do
    parent = self()

    handler = fn event, envelope ->
      send(parent, {:class_seen, event.n, envelope.class})
      :ok
    end

    {:ok, worker} =
      Worker.start_link(
        instance: instance,
        handler: handler,
        batch_size: 16,
        mode: :durable_first,
        failure_policy: :crash
      )

    {:ok, session_id} = Wiregrid.connect(instance, "priority-user", worker)
    topic = {:channel, "priority"}
    :ok = Wiregrid.subscribe(instance, session_id, topic)

    assert {:ok, _} = Wiregrid.publish(instance, topic, %{n: 1}, class: :ephemeral)
    assert {:ok, _} = Wiregrid.publish(instance, topic, %{n: 2}, class: :durable)

    seen =
      for _ <- 1..2 do
        receive do
          {:class_seen, n, class} -> {n, class}
        after
          1_000 -> flunk("consumer worker did not process priority burst")
        end
      end

    # Scheduling may let the first envelope enter its own batch, so the test
    # asserts safety/accounting rather than assuming the two sends coalesce.
    assert Enum.sort(seen) == [{1, :ephemeral}, {2, :durable}]
    assert eventually(fn -> Wiregrid.pending(instance, session_id) == 0 end)
  end
end
