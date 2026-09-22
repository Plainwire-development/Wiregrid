defmodule Wiregrid.SecurityBoundaryTest do
  use Wiregrid.TestCase, async: false

  @moduletag wiregrid_opts: [authorizer: Wiregrid.TestAuthorizer.DenyPublish]

  test "authorization happens before persistence", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())
    topic = {:channel, "private"}
    :ok = Wiregrid.subscribe(instance, sid, topic)

    assert {:error, :unauthorized} =
             Wiregrid.publish(instance, topic, %{secret: true},
               session_id: sid,
               event_id: "denied-event",
               persist: true
             )

    assert :not_found = Wiregrid.Storage.get(instance, topic, "denied-event")
  end

  test "authorizer exceptions fail closed" do
    instance = {:auth_crash, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        authorizer: Wiregrid.TestAuthorizer.Crash
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())
    assert {:error, :authorization_failed} = Wiregrid.subscribe(instance, sid, {:channel, "x"})
  end

  test "strict security mode refuses the permissive default authorizer" do
    assert {:error, :strict_security_requires_authorizer} =
             Wiregrid.Config.build(profile: :small, security_mode: :strict)

    assert {:ok, cfg} =
             Wiregrid.Config.build(
               profile: :small,
               security_mode: :strict,
               authorizer: Wiregrid.Authorizer.DenyAll
             )

    assert cfg.security_mode == :strict
    assert cfg.authorizer == Wiregrid.Authorizer.DenyAll
  end

  test "webhook URL validation is HTTPS and request-target strict" do
    assert :ok =
             Wiregrid.Webhook.Client.validate_destination("https://example.com/hooks/wiregrid", [
               "example.com"
             ])

    assert {:error, :webhook_destination_not_allowed} =
             Wiregrid.Webhook.Client.validate_destination("http://example.com/hooks", [
               "example.com"
             ])

    assert {:error, :non_ascii_hostname} =
             Wiregrid.Webhook.Client.validate_destination("https://éxample.com/hooks", [
               "éxample.com"
             ])
  end

  test "disconnect racing ephemeral writes leaves no activity or receipt state", %{
    instance: instance
  } do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, sid} = Wiregrid.connect(instance, "race-user", owner)
    topic = {:channel, "race"}

    writers =
      for n <- 1..64 do
        Task.async(fn ->
          _ = Wiregrid.activity(instance, sid, topic, :cursor, %{n: n}, ttl_ms: 5_000)
          _ = Wiregrid.receipt(instance, sid, %{id: "r-#{n}", n: n}, ttl_ms: 5_000)
        end)
      end

    _ = Wiregrid.disconnect(instance, sid, :test_race)
    Enum.each(writers, &Task.await(&1, 5_000))

    assert eventually(fn -> Wiregrid.activities(instance, topic, :cursor) == [] end, 1_500)

    for n <- 1..64 do
      assert Wiregrid.get_receipt(instance, sid, "r-#{n}") == :miss
    end

    Process.exit(owner, :kill)
  end

  test "webhook signatures verify with a bounded replay window and reject tampering" do
    secret = :crypto.strong_rand_bytes(32)
    body = <<0, 1, 2, 3, 255>>
    timestamp = 1_700_000_000
    nonce = "nonce-123"
    id = "delivery-123"

    assert {:ok, signature} =
             Wiregrid.Webhook.Signature.sign(secret, id, body, timestamp, nonce)

    assert :ok =
             Wiregrid.Webhook.Signature.verify(
               signature,
               secret,
               id,
               body,
               timestamp,
               nonce,
               now: timestamp,
               max_skew_seconds: 30
             )

    assert {:error, :invalid_webhook_signature} =
             Wiregrid.Webhook.Signature.verify(
               signature,
               secret,
               id,
               body <> "tampered",
               timestamp,
               nonce,
               now: timestamp
             )

    assert {:error, :webhook_timestamp_outside_window} =
             Wiregrid.Webhook.Signature.verify(
               signature,
               secret,
               id,
               body,
               timestamp,
               nonce,
               now: timestamp + 301
             )
  end

  test "events reject process-local resources and excessive structural complexity", %{
    instance: instance
  } do
    assert {:error, :invalid_event} =
             Wiregrid.publish(instance, {:channel, "events"}, %{pid: self()})

    assert {:error, :invalid_event} =
             Wiregrid.publish(instance, {:channel, "events"}, %{ref: make_ref()})

    assert {:error, :invalid_event} =
             Wiregrid.publish(instance, {:channel, "events"}, %{fun: fn -> :ok end})

    huge = Enum.to_list(1..70_000)
    assert {:error, :event_too_complex} = Wiregrid.publish(instance, {:channel, "events"}, huge)
  end
end
