# load testing

`scripts/load.sh` drives the public wiregrid api. it does not cheat by editing internal ets tables.

use environment variables such as `USERS`, `SESSIONS_PER_USER`, `TOPICS`, `SUBSCRIPTIONS_PER_SESSION`, `MESSAGES`, `MESSAGES_PER_SEC`, `DURATION_S`, `ACK_DELAY_MS`, `SLOW_PERCENT`, `RECONNECT_PERCENT`, and `ROOM_CHURN_PERCENT` to shape the run.

it reports publish throughput, delivery count, p50/p95/p99 delivery latency, errors, ets memory words, and remaining delivery reservations. it also exercises presence, ephemeral traffic, reconnect/resume, and room churn.

benchmark results only mean something with the workload written beside them. record hardware, otp/elixir versions, wiregrid config, event size, subscribers per topic, ack behavior, and external datastore setup.
