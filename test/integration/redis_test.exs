defmodule Wiregrid.RedisIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "Redis adapter preserves value/counter namespaces and TTL" do
    url = System.fetch_env!("WIREGRID_REDIS_URL")
    {:ok, conn} = Redix.start_link(url)
    instance = {:redis_integration, System.unique_integer([:positive])}
    prefix = "wg-test-#{System.unique_integer([:positive])}:"

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        cache: {Wiregrid.Cache.Redis, conn: conn, prefix: prefix}
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    assert :ok = Wiregrid.Cache.put(instance, "value", %{ok: true}, 5_000)
    assert {:ok, %{ok: true}} = Wiregrid.Cache.get(instance, "value")
    assert {:ok, 1} = Wiregrid.Cache.incr(instance, "count", 1, 5_000)
    assert {:ok, 3} = Wiregrid.Cache.incr(instance, "count", 2, 5_000)
    assert {:ok, 3} = Wiregrid.Cache.get(instance, "count")
  end
end
