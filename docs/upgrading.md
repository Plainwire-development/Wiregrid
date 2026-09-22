# upgrading

1.0.0 is the first published release. the elixir api and the plain-term `wiregrid_api` facade are the compatibility surfaces. internal ets layouts and process names are not public api.

foreign clients share channel names with `Wiregrid.Chat`. the gateway rejects anonymous sessions unless `allow_anonymous: true` is set on a loopback bind. chat payloads on the foreign socket and the json websocket are json.

before upgrading:

1. read `CHANGELOG.md`
2. run `./scripts/verify.sh` on the target otp/elixir versions
3. run the adapter integration tests against staging services
4. run the load harness with realistic event sizes and fanout
5. drain instances before replacing nodes when the deployment allows it

storage migrations in the current 1.x line are additive/idempotent around the original schema.

never assume an in-memory session or resume cache survives a full node restart. durable application state belongs in durable storage.
