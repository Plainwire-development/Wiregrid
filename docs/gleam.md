# gleam

`bindings/gleam` targets erlang and calls the plain-term `wiregrid_api`. there is no second runtime for gleam.

routing concepts such as topics, targets, presence, signals, delivery class, and prepared handles use closed gleam types. application event bodies and metadata stay `Dynamic` because wiregrid does not own your message schema.

it covers lifecycle, resumable sessions, subscriptions, normal/prepared fanout, direct sends, heterogeneous dispatch, encoded delivery, grouped acknowledgements, presence, rooms, signaling, activity, receipts, rate limiting, storage/cache access, replay, health, draining, and shutdown.

for high fanout, an encoded session can keep the already encoded payload in the delivery envelope and let the consumer decode only when needed.

runtime discovery is available through `version`, `protocol_version`, `capabilities`, and `describe`.

run the binding check with:

```sh
./scripts/check-gleam.sh
```

ci pins gleam 1.18.1. set `WIREGRID_REQUIRE_GLEAM=1` in a release environment if a missing compiler should fail the build instead of skipping the compile check.

## replay

`wiregrid.replay_session` exposes the bounded replay primitive. use `replay_session_with_options` when you need an explicit cursor, smaller page, ephemeral replay class, or separate delivery topic.
