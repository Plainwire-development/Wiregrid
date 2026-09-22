defmodule Wiregrid.ObservabilityTest do
  use Wiregrid.TestCase, async: true

  test "Prometheus output has fixed aggregate names and no application identifiers", %{
    instance: instance
  } do
    {:ok, sid} = Wiregrid.connect(instance, "sensitive-user-id", self())
    :ok = Wiregrid.subscribe(instance, sid, {:channel, "secret-room-name"})

    assert {:ok, body} = Wiregrid.prometheus_metrics(instance)
    assert body =~ "# TYPE wiregrid_sessions gauge"
    assert body =~ "wiregrid_sessions 1"
    assert body =~ "# TYPE wiregrid_connections_total counter"
    refute body =~ "sensitive-user-id"
    refute body =~ "secret-room-name"
  end
end
