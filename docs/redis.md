# redis cache

redis is an optional cache/counter adapter. it is not wiregrid's durable message history.

```elixir
cache: {Wiregrid.Cache.Redis, conn: redix, prefix: "myapp:wg:"}
```

normal values and counters use different key namespaces. writing a normal value removes an old counter atomically. counter increments reject normal-value keys and apply increment plus ttl in one lua operation.

prefixes are bounded and reject control characters.

use a different prefix per app/environment. authentication and tls belong on the caller-owned redix connection. wiregrid does not expose arbitrary redis commands through the cache api.
