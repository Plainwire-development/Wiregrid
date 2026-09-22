# getting started

wiregrid needs erlang/otp and elixir 1.17 or newer. the core runtime does not require third party packages.

for a checkout, run:

```sh
./scripts/doctor.sh
./scripts/setup-dev.sh
```

## the easy chat api

if you are making chat, use `Wiregrid.Chat` first. it gives normal names to the common operations and still goes through the regular wiregrid runtime underneath.

```sh
mix wiregrid.gen.chat MyApp.Chat --instance chat --profile small
```

add the generated module to your supervision tree, then:

```elixir
{:ok, session} = MyApp.Chat.connect("user-123")
:ok = MyApp.Chat.join(session, "general")
{:ok, _result} = MyApp.Chat.say(session, "general", "hello")
```

`Wiregrid.Chat.say/4` stores normal channel messages by default. history uses the same stream:

```elixir
{:ok, rows, next_cursor} = MyApp.Chat.history("general", nil, 100)
```

direct messages sent with `whisper/4` use the recipient's durable user stream and can be read with `inbox_history/3`.

## the lower level api

use `Wiregrid` directly when the app needs custom topics, delivery classes, prepared fanout, unusual persistence rules, or its own chat model.

```elixir
{:ok, _} = Wiregrid.start_instance(:chat, profile: :small)
{:ok, session} = Wiregrid.connect(:chat, "user-123", self())
:ok = Wiregrid.subscribe(:chat, session, {:channel, "general"})
{:ok, _} = Wiregrid.publish(:chat, {:channel, "general"}, %{type: :message, body: "hello"})
```

messages arrive in the owner process as `{:"$wiregrid", envelope}`. durable deliveries keep a reservation until they are acknowledged.

```elixir
receive do
  {:"$wiregrid", envelope} ->
    # do the work first, then ack it
    Wiregrid.ack(:chat, envelope.session_id, envelope.delivery_id)
end
```

ephemeral traffic can be dropped at the soft pressure limit. durable traffic is allowed up to the hard limit and then stops being admitted until pressure comes back down.

## reconnecting

resumable sessions use one time tokens. the token rotates after a successful resume.

```elixir
{:ok, _session, token} = Wiregrid.connect_resumable(:chat, "user-123", self())

# later, from the replacement connection process
{:ok, result} = Wiregrid.resume_session(:chat, "user-123", self(), token)
```

restored subscriptions, rooms, and presence watches are authorized again. a resume is not a way around current permissions.

## storage and cache

pass adapters when the instance starts:

```elixir
Wiregrid.start_instance(:chat,
  storage: {Wiregrid.Storage.Postgres, conn: MyApp.Postgres},
  cache: {Wiregrid.Cache.Redis, conn: MyApp.Redis}
)
```

connections and pools belong to your app. wiregrid does not hide database credentials or pool ownership inside the library.

if an adapter may block, use `adapter_mode: :isolated` and give it a real timeout and pending-work cap.

## clients outside the beam

run `Wiregrid.Foreign.Gateway` and use the c client or a wrapper around it. the gateway is optional and listens on loopback by default. read `foreign-clients.md` before exposing it anywhere else.

`scripts/install.sh` puts the c library and the browser kit on a prefix. a published tag can be installed with `curl -fsSL https://raw.githubusercontent.com/Plainwire-development/Wiregrid/v1.0.0/scripts/install.sh | sh`. `foreign-clients.md` and `ui.md` say where the files land and how to compile or import them.

## before real traffic

read `configuration.md`, `security.md`, and `operations.md`, then run `./scripts/verify.sh` on the exact otp/elixir versions you plan to deploy. run the load harness with realistic message sizes and subscriber counts too; a benchmark with tiny messages and one subscriber per topic does not tell you much about a busy chat app.
