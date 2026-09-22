defmodule Wiregrid.ScyllaIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :scylla_integration

  test "Scylla adapter bootstrap, idempotent append and page" do
    node = System.get_env("WIREGRID_SCYLLA_NODE", "127.0.0.1:9042")
    {:ok, conn} = Xandra.start_link(nodes: [node])
    instance = {:scylla_integration, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        storage:
          {Wiregrid.Storage.Scylla, conn: conn, keyspace: "wiregrid", replication_factor: 1}
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    assert :ok = Wiregrid.Storage.bootstrap(instance)
    stream = {:channel, "integration"}
    assert :ok = Wiregrid.Storage.append(instance, stream, "s1", %{body: "one"})
    assert :ok = Wiregrid.Storage.append(instance, stream, "s1", %{body: "retry"})

    assert {:ok, %{id: "s1", event: %{body: "one"}}} =
             Wiregrid.Storage.get(instance, stream, "s1")

    assert {:ok, [_], nil} = Wiregrid.Storage.page(instance, stream, nil, 10)
  end
end
