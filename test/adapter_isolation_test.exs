defmodule Wiregrid.AdapterIsolationTest do
  use ExUnit.Case, async: false

  defmodule SlowCache do
    def get(_opts, _key),
      do:
        (
          Process.sleep(100)
          :miss
        )

    def put(_opts, _key, _value, _ttl), do: :ok
    def delete(_opts, _key), do: :ok
    def incr(_opts, _key, _delta, _ttl), do: {:ok, 1}
    def health(_opts), do: :ok
  end

  test "isolated adapters time out without leaking capacity" do
    name = {:adapter_isolation, System.unique_integer([:positive])}

    assert {:ok, _} =
             Wiregrid.start_instance(name,
               profile: :small,
               adapter_mode: :isolated,
               adapter_timeout_ms: 10,
               max_adapter_pending: 2,
               cache: {SlowCache, []}
             )

    assert {:error, :adapter_timeout} = Wiregrid.Cache.get(name, "slow")
    assert Wiregrid.Health.stats(name).adapter_pending == 0
    assert Wiregrid.Metrics.get(name, :adapter_timeouts) == 1
    assert :ok = Wiregrid.stop_instance(name)
  end
end
