defmodule Wiregrid.TopologySyncAndDispatchPlanTest do
  use Wiregrid.TestCase, async: false

  test "subscription reconciliation converges to the exact desired set", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "sync-user", self())
    a = {:channel, "a"}
    b = {:channel, "b"}
    c = {:channel, "c"}

    assert {:ok, %{added: 2, removed: 0, unchanged: 0, desired: 2, partial: false}} =
             Wiregrid.sync_subscriptions(instance, sid, [a, b])

    assert {:ok, current} = Wiregrid.subscriptions(instance, sid)
    assert MapSet.new(current) == MapSet.new([a, b])

    assert {:ok, %{added: 1, removed: 1, unchanged: 1, desired: 2, partial: false}} =
             Wiregrid.sync_subscriptions(instance, sid, [b, c])

    assert {:ok, current} = Wiregrid.subscriptions(instance, sid)
    assert MapSet.new(current) == MapSet.new([b, c])
    assert {:ok, 0} = Wiregrid.topic_subscriber_count(instance, a)
    assert {:ok, 1} = Wiregrid.topic_subscriber_count(instance, b)
    assert {:ok, 1} = Wiregrid.topic_subscriber_count(instance, c)

    assert {:error, :duplicate_batch_items} =
             Wiregrid.sync_subscriptions(instance, sid, [b, b])

    stats = Wiregrid.stats(instance)
    assert stats.topology_syncs >= 2
  end

  test "reconciliation rolls back newly added edges when authorization rejects an addition" do
    instance = {:sync_rollback, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        cluster: false,
        authorizer: Wiregrid.TestAuthorizer.DenyOneSubscription
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)

    {:ok, sid} = Wiregrid.connect(instance, "rollback-user", self())
    existing = {:channel, "existing"}
    allowed = {:channel, "allowed"}
    denied = {:channel, "denied"}
    assert :ok = Wiregrid.subscribe(instance, sid, existing)

    assert {:error, {:sync_failed, %{phase: :add, reason: :denied_topic}}} =
             Wiregrid.sync_subscriptions(instance, sid, [existing, allowed, denied])

    assert {:ok, current} = Wiregrid.subscriptions(instance, sid)
    assert MapSet.new(current) == MapSet.new([existing])
    assert Wiregrid.stats(instance).topology_sync_failures >= 1
  end

  test "presence-watch and room reconciliation use the same exact-state semantics", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "topology-user", self())
    room_a = {:room, "a"}
    room_b = {:room, "b"}

    assert {:ok, %{added: 2, desired: 2, partial: false}} =
             Wiregrid.sync_presence_watches(instance, sid, ["alice", "bob"])

    assert {:ok, watches} = Wiregrid.presence_watches(instance, sid)
    assert MapSet.new(watches) == MapSet.new(["alice", "bob"])

    assert {:ok, %{added: 1, removed: 1, unchanged: 1, partial: false}} =
             Wiregrid.sync_presence_watches(instance, sid, ["bob", "carol"])

    assert {:ok, watches} = Wiregrid.presence_watches(instance, sid)
    assert MapSet.new(watches) == MapSet.new(["bob", "carol"])

    assert {:ok, %{added: 2, desired: 2, partial: false}} =
             Wiregrid.sync_rooms(instance, sid, [room_a, room_b])

    assert {:ok, rooms} = Wiregrid.session_rooms(instance, sid)
    assert MapSet.new(rooms) == MapSet.new([room_a, room_b])

    assert {:ok, %{added: 0, removed: 1, unchanged: 1, partial: false}} =
             Wiregrid.sync_rooms(instance, sid, [room_b])

    assert {:ok, [^room_b]} = Wiregrid.session_rooms(instance, sid)
  end

  test "dispatch plans deduplicate targets and remain integrity and instance bound", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "plan-user", self())
    topic = {:channel, "plan"}
    assert :ok = Wiregrid.subscribe(instance, sid, topic)

    targets = [
      {:topic, topic},
      {:topic, topic},
      {:session, sid}
    ]

    assert {:ok, plan} = Wiregrid.compile_dispatch(instance, targets)

    assert {:ok, %{target_count: 2, failed_groups: 0, partial: false}} =
             Wiregrid.dispatch_plan(instance, plan, %{kind: :planned})

    envelopes = for _ <- 1..2, do: elem(receive_delivery(), 1)
    assert Enum.all?(envelopes, &(&1.event == %{kind: :planned}))
    Enum.each(envelopes, fn envelope -> assert {:ok, _} = ack_delivery(instance, envelope) end)

    assert Wiregrid.pending(instance, sid) == 0
    stats = Wiregrid.stats(instance)
    assert stats.dispatch_plans_compiled >= 1
    assert stats.dispatch_plan_executions >= 1

    {:wiregrid_dispatch_plan_v1, groups, mac} = plan
    tampered = {:wiregrid_dispatch_plan_v1, Map.put(groups, :count, groups.count + 1), mac}
    assert {:error, :invalid_dispatch_plan} = Wiregrid.dispatch_plan(instance, tampered, :bad)

    other = {:dispatch_plan_other, System.unique_integer([:positive])}
    {:ok, _} = Wiregrid.start_instance(other, profile: :small, cluster: false)
    on_exit(fn -> Wiregrid.stop_instance(other) end)
    assert {:error, :invalid_dispatch_plan} = Wiregrid.dispatch_plan(other, plan, :cross_instance)
  end

  test "forged oversized dispatch plans are rejected within the configured target budget", %{
    instance: instance
  } do
    # The HMAC is intentionally invalid. Shape validation must stop after the
    # configured target ceiling instead of traversing the complete attacker-
    # supplied list before rejecting the plan.
    oversized = List.duplicate({:channel, "forged"}, 4_097)

    forged =
      {:wiregrid_dispatch_plan_v1,
       %{topics: oversized, rooms: [], users: [], sessions: [], count: 4_096},
       :binary.copy(<<0>>, 32)}

    assert {:error, :invalid_dispatch_plan} = Wiregrid.dispatch_plan(instance, forged, :payload)
  end

  test "prepared dispatch plans preserve prepared-event integrity", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "prepared-plan", self())
    assert {:ok, plan} = Wiregrid.compile_dispatch(instance, [{:session, sid}])
    assert {:ok, prepared} = Wiregrid.prepare(instance, %{kind: :prepared_plan})

    assert {:ok, %{target_count: 1, failed_groups: 0}} =
             Wiregrid.dispatch_plan_prepared(instance, plan, prepared)

    {_id, envelope} = receive_delivery()
    assert envelope.event == %{kind: :prepared_plan}
    assert {:ok, 0} = ack_delivery(instance, envelope)
  end

  test "combined topology reconciliation runs selected domains without interleaving", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "combined-topology", self())
    old_topic = {:channel, "old"}
    new_topic = {:channel, "new"}
    room = {:room, "combined"}
    assert :ok = Wiregrid.subscribe(instance, sid, old_topic)
    assert :ok = Wiregrid.watch_presence(instance, sid, "old-watch")

    assert {:ok, report} =
             Wiregrid.sync_topology(instance, sid, %{
               subscriptions: [new_topic],
               presence_watches: ["new-watch"],
               rooms: [room]
             })

    assert report.requested_domains == 3
    assert report.failed_domains == 0
    refute report.partial
    assert Enum.all?(report.domains, fn {_domain, result} -> result.status == :ok end)

    assert {:ok, [^new_topic]} = Wiregrid.subscriptions(instance, sid)
    assert {:ok, ["new-watch"]} = Wiregrid.presence_watches(instance, sid)
    assert {:ok, [^room]} = Wiregrid.session_rooms(instance, sid)

    # Omitted domains are left untouched, which lets callers reconcile only the
    # part of topology they own.
    assert {:ok, %{requested_domains: 1, failed_domains: 0}} =
             Wiregrid.sync_topology(instance, sid, %{subscriptions: []})

    assert {:ok, []} = Wiregrid.subscriptions(instance, sid)
    assert {:ok, ["new-watch"]} = Wiregrid.presence_watches(instance, sid)
    assert {:ok, [^room]} = Wiregrid.session_rooms(instance, sid)

    assert {:error, :invalid_topology} = Wiregrid.sync_topology(instance, sid, %{})
    assert {:error, :invalid_topology} = Wiregrid.sync_topology(instance, sid, %{unknown: []})
  end
end
