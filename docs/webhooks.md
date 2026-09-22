# webhooks

webhooks are optional and off by default. enabling them requires an explicit hostname allowlist.

pending jobs, concurrent workers, retries, and backoff are all bounded. jobs live in per-instance ets so dispatcher/runtime child restarts can recover outstanding work while table ownership survives.

on every attempt, wiregrid resolves the destination again and rejects private, loopback, link-local, multicast, mapped-private, nat64/6to4/teredo/internal/documentation ranges.

it connects to the validated address while keeping tls hostname and sni verification for the original host. redirects are not followed.

request target, headers, body, response headers/body, timeout, and retry count are bounded.

delivery is at least once. use `x-wiregrid-id` to deduplicate if the receiving action must be idempotent.

## signatures

wiregrid sends `x-wiregrid-id`, `x-wiregrid-timestamp`, `x-wiregrid-nonce`, and `x-wiregrid-signature`.

the signature is hmac-sha256 over the exact bytes `timestamp.nonce.delivery_id.body` and is encoded as `v1=<lowercase hex>`.

receivers can use the built-in verifier:

```elixir
:ok =
  Wiregrid.Webhook.Signature.verify(
    signature, secret, delivery_id, body, timestamp, nonce,
    max_skew_seconds: 300
  )
```

the verifier does not keep a replay database. durable deduplication belongs to the receiver because retention/idempotency needs are product-specific.

do not log webhook secrets.
