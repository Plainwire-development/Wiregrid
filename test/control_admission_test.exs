defmodule Wiregrid.ControlAdmissionTest do
  use Wiregrid.TestCase, async: false

  @tag wiregrid_opts: [
         authorizer: Wiregrid.TestAuthorizer.SlowSubscribe,
         max_control_pending: 1,
         control_call_timeout_ms: 2_000
       ]
  test "control mailbox admission rejects excess queued lifecycle work", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())

    first = Task.async(fn -> Wiregrid.subscribe(instance, sid, {:channel, "one"}) end)
    Process.sleep(30)

    second = Task.async(fn -> Wiregrid.subscribe(instance, sid, {:channel, "two"}) end)
    Process.sleep(30)

    assert {:error, :control_overloaded} = Wiregrid.subscribe(instance, sid, {:channel, "three"})
    assert :ok = Task.await(first, 2_000)
    assert :ok = Task.await(second, 2_000)

    assert {:ok, pressure} = Wiregrid.pressure(instance)
    assert pressure.control_pending.used == 0
    assert Wiregrid.stats(instance).control_rejections >= 1
  end

  test "expiry scheduler has an explicit admission budget" do
    assert {:ok, cfg} = Wiregrid.Config.build(profile: :small)
    assert cfg.max_expiry_entries > 0
    assert cfg.max_control_pending > 0
    assert cfg.control_call_timeout_ms > 0
  end
end
