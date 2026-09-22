# changelog

## 1.0.0

first published release.

the runtime covers sessions, subscriptions, fanout, presence, rooms, acknowledgements, reconnects, storage, rate limits, and optional clustering. elixir is the main api. erlang, gleam, and lfe call the same engine. `Wiregrid.Chat` is the short path for channels, direct messages, typing, reactions, edits, and history.

`priv/ui` is a css and javascript kit. classes start with `wg-`, utilities with `wg-u-`, and most of the look comes from css variables. `chat.html` is a static shell. `connectChat` speaks the json websocket protocol.

the c library in `native/c` talks to `Wiregrid.Foreign.Gateway`. other languages wrap that abi. channel names match the chat api, and chat payloads on that socket are json. `wg_history` pages a stream the session is allowed to read.

the gateway listens on loopback and rejects anonymous sessions unless `allow_anonymous: true` is set on that loopback bind.

`scripts/install.sh` installs the c library, the browser ui kit, and the gleam, lfe, and erlang sources onto a prefix. elixir stays a mix dependency. a `v*` tag publishes a linux tarball on the github release, and the install script checks `SHA256SUMS` when that file is attached.
