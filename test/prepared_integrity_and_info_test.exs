defmodule Wiregrid.PreparedIntegrityAndInfoTest do
  use Wiregrid.TestCase, async: false

  test "prepared handles are bound to their instance and exact event/payload", %{
    instance: instance
  } do
    event = %{kind: :prepared, value: 42}
    assert {:ok, prepared} = Wiregrid.prepare(instance, event)
    assert {:wiregrid_prepared_v2, codec, ^event, payload, mac} = prepared

    assert {:ok, ^event, ^payload} = Wiregrid.Prepared.unpack(instance, prepared)

    forged_event = {:wiregrid_prepared_v2, codec, %{kind: :forged}, payload, mac}
    assert {:error, :prepared_event_mismatch} = Wiregrid.Prepared.unpack(instance, forged_event)

    forged_payload = {:wiregrid_prepared_v2, codec, event, payload <> <<0>>, mac}
    assert {:error, :prepared_event_mismatch} = Wiregrid.Prepared.unpack(instance, forged_payload)

    forged_mac = {:wiregrid_prepared_v2, codec, event, payload, :crypto.strong_rand_bytes(32)}
    assert {:error, :prepared_event_mismatch} = Wiregrid.Prepared.unpack(instance, forged_mac)
  end

  test "prepared handles do not cross instance security domains", %{instance: instance} do
    assert {:ok, prepared} = Wiregrid.prepare(instance, %{kind: :private})
    other = {:prepared_other, System.unique_integer([:positive])}
    assert {:ok, _} = Wiregrid.start_instance(other, profile: :small, cluster: false)

    on_exit(fn -> _ = Wiregrid.stop_instance(other) end)

    assert {:error, :prepared_event_mismatch} = Wiregrid.Prepared.unpack(other, prepared)
  end

  test "capability discovery exposes operational metadata without adapter options", %{
    instance: instance
  } do
    assert is_binary(Wiregrid.version())
    assert Wiregrid.protocol_version() == 1

    assert {:ok, capabilities} = Wiregrid.capabilities(instance)
    assert capabilities.protocol_version == 1
    assert :delivery_backpressure in capabilities.features
    assert capabilities.profile == :small
    refute Map.has_key?(capabilities, :config)

    assert {:ok, description} = Wiregrid.describe(instance)
    assert description.capabilities == capabilities
    assert is_map(description.limits)
    assert is_map(description.health)
    assert is_map(description.pressure)
    assert is_map(description.stats)
  end
end
