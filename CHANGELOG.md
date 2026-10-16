# changelog

## unreleased

- bound foreign authentication attempts, hello deadlines and frame admission; monitor connection workers so crashes release capacity and gateway shutdown closes clients.
- preserve partial c poll frames, enforce total request deadlines with nonblocking io, reject malformed streams, and avoid truncated history cursors. c abi minor 2 adds borrowed-descriptor and pending-event accessors.
- preserve server event ids through live, prepared, batch, room, user, cluster and replay deliveries, including browser json and foreign events.
- add typed `mountChat` and indexed `createTimeline` components, bounded browser requests, optional metadata-only debug callbacks, and safe async composers for both esm and global bundles.
- run dom, typed-consumer and hostile native-peer regressions in the verification gates. update test-only xandra and decimal to remove decimal allocation denial-of-service advisories.

## 1.0.0

first published release.

the runtime covers sessions, subscriptions, fanout, presence, rooms, acknowledgements, reconnects, storage, rate limits, and optional clustering. elixir is the main api. erlang, gleam, and lfe call the same engine. `Wiregrid.Chat` is the short path for channels, direct messages, typing, reactions, edits, and history.

`priv/ui` is a css and javascript kit. classes start with `wg-`, utilities with `wg-u-`, and most of the look comes from css variables. `chat.html` is a static shell. `connectChat` speaks the json websocket protocol.

the c library in `native/c` talks to `Wiregrid.Foreign.Gateway`. other languages wrap that abi. channel names match the chat api, and chat payloads on that socket are json. `wg_history` pages a stream the session is allowed to read.

the gateway listens on loopback and rejects anonymous sessions unless `allow_anonymous: true` is set on that loopback bind.

`scripts/install.sh` installs the c library, the browser ui kit, and the gleam, lfe, and erlang sources onto a prefix. elixir stays a mix dependency. a `v*` tag publishes a linux tarball on the github release, and the install script checks `SHA256SUMS` when that file is attached.
