# wiregrid

wiregrid is a realtime chat app engine for beam apps, or other languages via c ffi (experimental). it handles the stuff that usually gets rebuilt around chat: sessions, subscriptions, fanout, presence, rooms, acknowledgements, reconnects, storage, rate limits, slow clients, and optional clustering.

elixir is the main api. there is also a plain erlang api, gleam and lfe bindings, a small browser ui package, and a c client abi for programs that do not run on the beam.

wiregrid does not own your users, roles, moderation rules, message schema, or product database. those stay in your app.

## getting a chat running

for a normal chat app, start with the chat wrapper instead of wiring every low level call yourself.

```elixir
defmodule MyApp.Chat do
  use Wiregrid.Chat,
    instance: :chat,
    options: [profile: :small]
end
```

put `MyApp.Chat` in your supervision tree, then use it like this:

```elixir
{:ok, session} = MyApp.Chat.connect("alice")
:ok = MyApp.Chat.join(session, "general")
{:ok, _result} = MyApp.Chat.say(session, "general", "hello")
```

channel messages sent through `say/4` are persisted by default. `history/3` reads the same stream back. if you need something unusual, use `Wiregrid` directly. the chat module is just the easy path, it is not a second engine.

## ui

there is an optional ui package under `priv/ui`. it is plain css and small javascript modules, so it can sit under phoenix, liveview, react, svelte, elm, or a hand written frontend without taking over the app.

```sh
mix wiregrid.ui.install
```

```css
@import "./wiregrid/wiregrid.css";

:root {
  --wg-accent: #7c8cff;
  --wg-sidebar: 280px;
  --wg-message-gap: 6px;
}
```

all public classes start with `wg-`. most of the look comes from css variables, so changing the theme does not require copying the whole stylesheet. the javascript helpers do not render raw user html for you; message text is written with `textContent`.

see `docs/ui.md` for the class layers, theme variables, and browser helpers.

## lfe

there is more lfe in this repo than a normal binding needs, and that is on purpose.

lfe is not another wiregrid runtime. elixir/erlang still owns the real state, validation, storage rules, authorization, and delivery accounting. lfe is used where it is actually nice to use: small actor loops, mailbox matching, bounded batch workers, fixed routing rules, and macros that can turn known chat topology into ordinary beam functions at compile time.

it is split into a bunch of small modules because those jobs have different failure and ordering rules. one giant `wiregrid_fast.lfe` file would be harder to reason about and easier to accidentally make unsafe. you can ignore all of it and wiregrid still runs normally.

```sh
mix wiregrid.lfe.compile
```

see `docs/lfe.md` if you actually plan to use the lfe side.

## c and other languages

`native/c` is a client library, not a nif. it talks to `Wiregrid.Foreign.Gateway` over a small versioned binary protocol.

that is a little less clever than loading native code into the vm, which is exactly why it is safer. a broken c, rust, zig, go, python, java, or dotnet client can kill its own process without taking the beam down with it, and none of those languages need to understand erlang term layouts.

```c
wg_client *client = NULL;
wg_client_options options;
wg_client_options_init(&options);
options.auth_token = getenv("WIREGRID_TOKEN");

if (wg_connect("127.0.0.1", 9567, "alice", &options, &client) == WG_OK) {
    wg_subscribe(client, "general");
    wg_publish(client, "general", "hello", 5, "text/plain", 1, NULL, 0);
    wg_close(client);
}
```

the gateway listens on loopback by default and rejects anonymous sessions. `allow_anonymous: true` is accepted only for a loopback bind. it does not do tls itself. if it leaves a trusted host or private network, put tls in front of it.

a c client subscribed to `general` is on the same channel as `MyApp.Chat.join(session, "general")`. publish chat messages as json (`application/json`) when the other side is elixir. raw bytes still work, and they arrive as a foreign payload rather than a chat event.

see `docs/foreign-clients.md` and `native/c/README.md`.

## local install

`scripts/install.sh` installs the c library, the browser ui kit, and the gleam, lfe, and erlang sources. set `PREFIX` to choose the directory. with `PREFIX` unset, root uses `/usr/local` when that directory exists, and any other user gets `~/.local`. on macos, a homebrew prefix you own is used when a system write to `/usr/local` is the wrong default.

elixir stays a mix dependency of the application that runs the node. mix compiles the beam files there. when the prefix sits outside the default linker path, the script prints the `PKG_CONFIG_PATH`, `LD_LIBRARY_PATH` or `DYLD_LIBRARY_PATH`, and `C_INCLUDE_PATH` lines to add.

`docs/foreign-clients.md` shows where the c files land and how to compile against them. `docs/ui.md` shows where the browser files land.

## release tarball

a `v*` tag publishes a github release. the linux x86_64 asset is `wiregrid-<version>-linux-x86_64.tar.gz`, and `SHA256SUMS` sits beside it. the install script checks that sha256 when the checksums file is there.

```sh
curl -fsSL https://raw.githubusercontent.com/Plainwire-development/Wiregrid/v1.0.0/scripts/install.sh | sh
```

`WIREGRID_VERSION` selects a tag (`v` is optional). `WIREGRID_TARBALL` selects an archive already on disk. a checkout that contains `native/c` and `priv/ui` builds the c library on this machine. `PREFIX` chooses the directory the same way as a local run.

## before production

start with `:balanced`, set a real authorizer for anything internet facing, use a durable adapter for data you care about, keep beam distribution private, and load test the same event sizes and fanout shape you expect in production.

adapter callbacks run inline by default. if an adapter can block unpredictably, use bounded isolation instead:

```elixir
Wiregrid.start_instance(:chat,
  adapter_mode: :isolated,
  adapter_timeout_ms: 2_000,
  max_adapter_pending: 512,
  storage: {MyApp.Storage, []}
)
```

when that pool is full, new adapter work is rejected instead of spawning forever.

run the normal checks before a release:

```sh
./scripts/doctor.sh
./scripts/verify.sh
./scripts/release-check.sh
```

and run the native client test if you ship the c side:

```sh
make -C native/c test
```

`docs/getting-started.md` is the short setup guide. `docs/architecture.md`, `docs/configuration.md`, `docs/security.md`, and `docs/operations.md` are the ones worth reading before you put real traffic on it.
