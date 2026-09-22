# configuration

wiregrid instances are configured when they start. there is no required global application config.

```elixir
Wiregrid.start_instance(:chat, profile: :balanced)
```

unknown or duplicate options are rejected. bad adapter modules fail startup instead of waiting until the first real request to explode.

## profiles

`:small` uses conservative limits for development, small vms, sbcs, and modest services.

`:balanced` is the normal starting point for production.

`:large` raises the ceilings for a measured deployment. it does not preallocate everything and it is not a magic performance mode.

profiles set limits for sessions, subscriptions, room/watch edges, activities, receipts, cache entries, delivery reservations, resume snapshots, event sizes, metadata sizes, frame sizes, queue pressure, ttl state, rate-limit buckets, adapter work, and cluster work.

if you expect unusual traffic, override the specific limit you understand instead of selecting `:large` just because the machine has a lot of ram.

## authorization

`Wiregrid.Authorizer.AllowAll` assumes trusted in-process callers. do not put an internet-facing transport in front of that and call it permission checking.

configure an authorizer implementing `authorize/4` for product permissions. callback crashes and invalid callback returns fail closed.

## adapters

adapter config is `{module, keyword_options}`. postgres, redis, and scylla connections/pools are created and owned by your app and passed with `conn:`.

keep credentials in the host application's runtime config or secret manager, not in wiregrid source/config checked into git.

trusted predictable adapters can run inline:

```elixir
storage: {MyApp.Storage, []}
```

for code that may block unpredictably, use bounded isolation:

```elixir
Wiregrid.start_instance(:chat,
  adapter_mode: :isolated,
  adapter_timeout_ms: 3_000,
  max_adapter_pending: 512,
  storage: {MyApp.Storage, []},
  cache: {MyApp.Cache, []}
)
```

when isolated capacity is full, new work is rejected instead of spawning another unbounded task. health and metrics include adapter pressure, failures, timeouts, and admission rejections.

## rate limiting

limiter state is local to the instance and bounded by `max_rate_limit_buckets`. fixed windows are cheap coarse quotas. token buckets are better when you want smoother admission and a defined burst.

read `rate-limiting.md` for examples.

## webhooks

webhooks are off by default. enabling them requires a non-empty hostname allowlist and bounded worker, queue, and retry settings.

read `webhooks.md` before turning them on.

## owner process limits

`max_sessions_per_owner` limits how many wiregrid sessions can share one owner pid. the stock profiles use `32` for `:small`, `128` for `:balanced`, and `1024` for `:large`.

wiregrid tracks delivery pressure per session, so this second limit stops one buggy transport process from attaching a huge number of individually valid sessions to one mailbox. it is separate from `max_sessions_per_user`.
