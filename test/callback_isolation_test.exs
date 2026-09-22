defmodule Wiregrid.CallbackIsolationTest do
  use Wiregrid.TestCase, async: false

  @tag wiregrid_opts: [
         authorizer: Wiregrid.TestAuthorizer.SlowAll,
         authorizer_mode: :isolated,
         callback_timeout_ms: 25,
         max_callback_pending: 4
       ]
  test "isolated authorizer times out fail-closed without crashing runtime", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())

    assert {:error, :authorization_timeout} =
             Wiregrid.subscribe(instance, sid, {:channel, "slow"})

    assert Wiregrid.liveness(instance) == :alive
    assert %{status: :ok} = Wiregrid.health(instance)
    assert {:ok, pressure} = Wiregrid.pressure(instance)
    assert pressure.callback_pending.used == 0
  end

  test "authorizer execution mode is explicit and validated" do
    assert {:ok, inline} = Wiregrid.Config.build(profile: :small, authorizer_mode: :inline)
    assert inline.authorizer_mode == :inline

    assert {:ok, isolated} =
             Wiregrid.Config.build(
               profile: :small,
               authorizer_mode: :isolated,
               callback_timeout_ms: 50
             )

    assert isolated.authorizer_mode == :isolated

    assert {:error, :invalid_authorizer_mode} =
             Wiregrid.Config.build(profile: :small, authorizer_mode: :mystery)
  end
end
