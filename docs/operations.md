# operations

use `health/1`, `readiness/1`, `liveness/1`, and `stats/1` for service checks and dashboards.

readiness becomes false while an instance is draining. health includes runtime/expiry status and adapter health.

`drain/1` stops new work from being admitted while still allowing acknowledgements and cleanup. `await_idle/2` waits for delivery reservations, webhook work, and cluster pending work to reach zero. `graceful_shutdown/2` combines draining, waiting, and stopping the instance.

watch sessions, users, subscriptions, rooms, delivery reservations, slow consumers, dropped ephemeral events, admission rejections, rate-limit rejections, adapter pressure/timeouts, webhook work, cluster pending work, node count, and ets memory.

wiregrid telemetry is local. your application decides whether it goes to prometheus, opentelemetry, logs, or nowhere.

for durable adapters, monitor the caller-owned database/cache pools too. a healthy wiregrid runtime cannot make an exhausted postgres pool healthy.

## a basic production checklist

before shipping a new version:

- run `./scripts/verify.sh` on the target otp/elixir toolchain
- run adapter integration tests against staging services that match production closely
- run the load harness with realistic message sizes, fanout, ack delay, reconnects, and slow clients
- make sure the instance limits are intentional, not just copied from `:large`
- make sure internet-facing paths have authentication and authorization
- keep beam distribution private
- verify database backups and restore procedures separately from wiregrid
- use drain/graceful shutdown during rolling replacement where possible

benchmark numbers are local to the machine and workload that produced them. keep the hardware, otp/elixir versions, configuration, event sizes, subscriber distribution, and datastore setup beside any capacity number you publish internally.
