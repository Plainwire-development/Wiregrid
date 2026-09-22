defmodule Wiregrid.RateLimitAndValidationTest do
  use Wiregrid.TestCase, async: false

  test "rate limiter expires bounded buckets", %{instance: instance} do
    assert {:ok, 1} = Wiregrid.rate_limit(instance, :auth, "peer", 2, 50)
    assert {:ok, 0} = Wiregrid.rate_limit(instance, :auth, "peer", 2, 50)
    assert {:error, :rate_limited} = Wiregrid.rate_limit(instance, :auth, "peer", 2, 50)
    Process.sleep(70)
    assert {:ok, 1} = Wiregrid.rate_limit(instance, :auth, "peer", 2, 50)
  end

  test "public APIs reject malformed and oversized routing input", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "alice", self())
    assert {:error, :invalid_topic} = Wiregrid.subscribe(instance, sid, {make_ref(), "bad"})
    assert {:error, :invalid_topic} = Wiregrid.publish(instance, {self(), "bad"}, %{x: 1})
    assert {:error, :invalid_id} = Wiregrid.ack(instance, sid, "")
    assert {:error, :invalid_options} = Wiregrid.connect(instance, "bob", self(), [:not_keyword])
  end

  test "token bucket permits the configured burst and then sheds", %{instance: instance} do
    opts = [policy: :token_bucket, burst: 3, idle_ttl_ms: 1_000]

    assert {:ok, 2} = Wiregrid.rate_limit(instance, :publish, "alice", 1, 1_000, opts)
    assert {:ok, 1} = Wiregrid.rate_limit(instance, :publish, "alice", 1, 1_000, opts)
    assert {:ok, 0} = Wiregrid.rate_limit(instance, :publish, "alice", 1, 1_000, opts)

    assert {:error, :rate_limited} =
             Wiregrid.rate_limit(instance, :publish, "alice", 1, 1_000, opts)
  end

  test "rate limiter rejects unknown policies and malformed policy options", %{instance: instance} do
    assert {:error, :invalid_rate_limit_policy} =
             Wiregrid.rate_limit(instance, :auth, "peer", 10, 1_000, policy: :sliding_window)

    assert {:error, :invalid_rate_limit_burst} =
             Wiregrid.rate_limit(instance, :auth, "peer", 10, 1_000,
               policy: :token_bucket,
               burst: 0
             )

    assert {:error, {:unknown_options, [:made_up]}} =
             Wiregrid.rate_limit(instance, :auth, "peer", 10, 1_000, made_up: true)
  end

  test "stale limiter expiry generations cannot remove recreated token state", %{
    instance: instance
  } do
    opts = [policy: :token_bucket, burst: 1, idle_ttl_ms: 5_000]
    assert {:ok, 0} = Wiregrid.rate_limit(instance, :frame, "session-a", 1, 1_000, opts)

    assert {:error, :rate_limited} =
             Wiregrid.rate_limit(instance, :frame, "session-a", 1, 1_000, opts)

    composite = {:token_bucket, :frame, "session-a", 1, 1_000, 1}
    assert :ok = Wiregrid.RateLimiter.expire(instance, {composite, make_ref()})

    assert {:error, :rate_limited} =
             Wiregrid.rate_limit(instance, :frame, "session-a", 1, 1_000, opts)
  end

  test "token bucket admission stays bounded under contention", %{instance: instance} do
    opts = [policy: :token_bucket, burst: 16, idle_ttl_ms: 120_000]

    results =
      1..64
      |> Task.async_stream(
        fn _ -> Wiregrid.rate_limit(instance, :publish, "contended", 1, 60_000, opts) end,
        ordered: false,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    allowed = Enum.count(results, &match?({:ok, _}, &1))
    rejected = Enum.count(results, &(&1 == {:error, :rate_limited}))

    assert allowed == 16
    assert rejected == 48
  end

  test "option and topic validation rejects oversized shapes before expensive conversion", %{
    instance: instance
  } do
    oversized_opts = List.duplicate({:policy, :fixed_window}, 65)
    assert {:error, :too_many_options} = Wiregrid.Validation.keyword_opts(oversized_opts, [])

    huge_topic = List.to_tuple([:custom | List.duplicate("x", 10_000)])
    assert {:error, :invalid_topic} = Wiregrid.publish(instance, huge_topic, %{x: 1})
  end

  test "telemetry metric events are explicit opt-in" do
    assert {:ok, cfg} = Wiregrid.Config.build(profile: :small)
    assert cfg.telemetry_metric_events == false

    assert {:ok, enabled} = Wiregrid.Config.build(profile: :small, telemetry_metric_events: true)
    assert enabled.telemetry_metric_events == true

    assert {:error, :invalid_telemetry_metric_events} =
             Wiregrid.Config.build(profile: :small, telemetry_metric_events: :yes)
  end

  test "readiness pressure threshold is bounded" do
    assert {:ok, cfg} = Wiregrid.Config.build(profile: :small, readiness_pressure_threshold: 0.9)
    assert cfg.readiness_pressure_threshold == 0.9

    assert {:error, :invalid_readiness_pressure_threshold} =
             Wiregrid.Config.build(profile: :small, readiness_pressure_threshold: 0)

    assert {:error, :invalid_readiness_pressure_threshold} =
             Wiregrid.Config.build(profile: :small, readiness_pressure_threshold: 1.1)
  end
end
