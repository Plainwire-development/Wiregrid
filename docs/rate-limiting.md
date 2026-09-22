# rate limiting

wiregrid keeps bounded per-instance limiter state. it can be used for websocket frames, login attempts, publish/subscribe operations, webhooks, or app-defined operations.

```elixir
Wiregrid.rate_limit(:chat, :publish, session_id, 120, 60_000)
```

returns `{:ok, remaining}` or `{:error, :rate_limited}`.

unique limiter keys are bounded by `max_rate_limit_buckets`, so a caller cannot create unlimited limiter state just by sending new ids forever.

## fixed window

fixed windows are cheap and good for coarse quotas:

```elixir
Wiregrid.rate_limit(:chat, :login, peer_key, 20, 60_000,
  policy: :fixed_window
)
```

window ids use monotonic time. expiry rows are generation-tagged so an old expiry callback cannot remove a newly recreated bucket.

## token bucket

use a token bucket when burst smoothing matters:

```elixir
Wiregrid.rate_limit(:chat, :websocket_frame, session_id, 120, 60_000,
  policy: :token_bucket,
  burst: 30,
  idle_ttl_ms: 120_000
)
```

`limit/window_ms` sets the refill rate and `burst` sets the largest whole-token balance. the implementation uses integer arithmetic and ets compare-and-swap updates.

idle expiry is checked against the bucket's last-use timestamp, so an old timer cannot reset a live bucket that was refreshed after the timer was created.

## cowboy defaults

authentication uses fixed-window limiting by default. authenticated websocket frames use token-bucket limiting by default.

related options are `auth_rate_policy`, `auth_rate_burst`, `frame_rate_policy`, and `frame_rate_burst`, plus the normal rate/window settings.

## choosing keys

use a small stable value that represents the resource you are protecting, such as a session id, user id, peer ip tuple, webhook class, or app operation key.

wiregrid bounds encoded key size with `max_rate_limit_key_bytes`. do not build limiter keys from unbounded request bodies.

rate limiting is admission control, not authorization. a request that fits the rate still needs permission checking.
