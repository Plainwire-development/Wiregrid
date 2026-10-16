# security

wiregrid is infrastructure, not an identity system. it puts hard bounds around its own runtime, but your app still decides who a user is and what that user is allowed to do.

## what wiregrid bounds

identifiers, topics, routing terms, metadata, events, encoded payloads, cache values, websocket frames, webhook bodies and responses, ttl state, deliveries, limiter keys, adapter work, and cluster queues all have configured limits.

untrusted strings are not turned into atoms.

external erlang terms are decoded only through `Wiregrid.SafeTerm`, with `binary_to_term(..., [:safe])`, byte limits, and compressed etf rejection before decode.

transport tokens use a versioned binary envelope, hmac-sha256, constant-time comparison, expiry, audience binding, nonces, and key ids for rotation. whole-session resume tokens are random, stored as hashes, bound to the same user, one time, and rotated after a successful resume.

## what your app still owns

identity, role/permission rules, tls, database and cache credentials, network segmentation, beam distribution security, backups, host hardening, dependency updates, and product-specific abuse handling are outside the library.

`Wiregrid.Authorizer.AllowAll` is fine for trusted in-process code. internet-facing transports should use a real authorizer.

## network boundaries

cowboy authenticates before a wiregrid session is created, bounds headers and frames, and can enforce browser origin allowlists.

beam distribution should be treated as a trusted private network. do not expose epmd/distribution ports to the public internet. use private networking and tls distribution where it fits the deployment.

`Wiregrid.Foreign.Gateway` binds to loopback by default and uses a bounded protocol, but it does not provide tls. anonymous sessions are rejected unless `allow_anonymous: true` is set, and that option only starts when the bind address is loopback. keep the socket private or terminate tls before it, and pass an `authenticate` function for anything you do not fully trust.

foreign connections have absolute hello deadlines, a failed-authentication budget, per-connection frame admission and monitored connection slots. the c client uses nonblocking socket io and total request deadlines, preserves incomplete poll frames, and closes on protocol errors or request timeouts. browser requests have bounded pending work, send buffers and deadlines. see [foreign clients](foreign-clients.md) and [ui](ui.md) for the defaults and retry behavior.

## development dependencies

the production core has no mandatory third-party dependencies. test dependencies include decimal 3.1.2 or later to avoid [unbounded exponent allocation](https://github.com/ericmj/decimal/security/advisories/GHSA-rhv4-8758-jx7v) and [unbounded rounding allocation](https://github.com/ericmj/decimal/security/advisories/GHSA-6c27-994x-c52f); xandra 0.20 permits that version.

the otp 26-compatible cowboy test fixture still pins cowlib 2.19. hex reports link-header, structured-header, and cookie encoder advisories against that version. wiregrid's transport does not call those encoder functions, and the fixture is test-only; this does not certify a host application's use of cowlib. production applications supply their own cowboy dependency and should review [cowlib's current advisories](https://hex.pm/packages/cowlib/advisories) for the functions they use. updating to the latest cowlib alone does not clear every currently reported advisory.

webhooks resolve and validate destinations on every attempt, reject private/link-local/loopback/multicast and common internal transition ranges, connect to the validated address while preserving tls hostname/sni checks, do not follow redirects, and sign deliveries.

## privacy

wiregrid does not phone home or export telemetry on its own. logs are meant to avoid message bodies, authorization headers, bearer tokens, database credentials, and webhook secrets.

## before production

run the full verification script on the same otp/elixir line you deploy, run the integration tests for the adapters you actually use, keep secrets out of source, test restore/backups for durable storage, and load test with realistic fanout and event sizes.

no library can promise a deployment is vulnerability-free. if you find a security issue, use the private reporting path described in the top-level `SECURITY.md`.
