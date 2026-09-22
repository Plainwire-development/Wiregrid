defmodule Wiregrid.RecoveryTest do
  use ExUnit.Case, async: false

  test "rebuilds owner indexes and clears stale slow-consumer isolation" do
    instance = {:recovery_test, System.unique_integer([:positive])}
    {:ok, _pid} = Wiregrid.start_instance(instance)

    on_exit(fn ->
      _ = Wiregrid.stop_instance(instance)
    end)

    {:ok, session_id} = Wiregrid.connect(instance, "user", self())
    %{tables: t} = Wiregrid.Tables.get(instance)

    # Simulate derived-index loss and an eviction marker surviving the
    # control-plane process that created it.
    :ets.delete_all_objects(t.owner_sessions)
    :ets.delete_all_objects(t.owner_session_counts)
    true = :ets.insert(t.slow_evicting, {session_id, true})

    assert {:ok, _cfg} = Wiregrid.Recovery.reconcile(instance)
    assert [{pid, ^session_id}] = :ets.lookup(t.owner_sessions, self())
    assert pid == self()
    assert :wiregrid_hot.counter_get(t.owner_session_counts, self()) == 1
    refute :ets.member(t.slow_evicting, session_id)
  end
end

defmodule Wiregrid.RuntimeAdmissionRecoveryTest do
  use ExUnit.Case, async: false

  test "hot-path admission rejects a stale ready marker owned by a dead runtime" do
    instance = {:runtime_admission_test, System.unique_integer([:positive])}
    {:ok, _pid} = Wiregrid.start_instance(instance)

    on_exit(fn ->
      _ = Wiregrid.stop_instance(instance)
    end)

    %{tables: t} = Wiregrid.Tables.get(instance)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    true = :ets.insert(t.runtime_flags, {:control_ready, dead})
    assert {:error, :reindexing} = Wiregrid.Runtime.accepting(instance)
  end
end
