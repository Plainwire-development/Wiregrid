# foreign clients

wiregrid talks to non-beam programs through a small client protocol. the reference implementation is the c11 library in `native/c`.

this is not a nif. that choice is deliberate: native client code stays outside the beam vm, so a bad pointer in somebody's rust/c/python extension does not crash the node, and bindings do not need to know how erlang terms are laid out in memory.

## connection shape

clients connect to `Wiregrid.Foreign.Gateway`. each accepted connection owns a normal wiregrid session, which means subscriptions, authorization, acknowledgements, presence, and delivery pressure still use the same engine as elixir callers.

transport is tcp with erlang `packet: 4` framing. inside each packet is a small versioned tlv message.

protocol 1 starts with this header:

| bytes | field |
| ---: | --- |
| 1 | protocol version |
| 1 | kind (`request`, `response`, or `event`) |
| 1 | operation |
| 4 | unsigned request id, big-endian |

after that come zero or more fields. a field is one byte of tag, four bytes of big-endian length, then the raw value.

protocol 1 limits a frame to 2 mib, a single field to 1 mib, and a frame to 32 fields. duplicate tags are rejected. unknown tags can be ignored, which gives the protocol room for additive fields later.

current operations are `hello`, `subscribe`, `unsubscribe`, `publish`, `ack`, `presence`, `join_room`, `leave_room`, and `ping`. deliveries arrive as asynchronous `event` frames.

payload bodies are just bytes with a content type. json apps can send json, protobuf apps can send protobuf, and so on. foreign clients never have to decode erlang external terms.

## running the gateway

```elixir
children = [
  MyApp.Chat,
  {Wiregrid.Foreign.Gateway,
   instance: :chat,
   port: 9567,
   max_connections: 2_000,
   authenticate: fn user_id, token -> MyApp.ForeignAuth.check(user_id, token) end}
]
```

it listens on `127.0.0.1` by default. a connection is refused at `hello` unless you pass `authenticate`, or you set `allow_anonymous: true` while the bind address is loopback. `allow_anonymous` on any other address fails at startup.

there is no tls layer inside the protocol. keep the gateway on loopback or a private network, or put a tls proxy/terminator in front of it. keep the authenticate callback bounded.

`authenticate` receives the requested user id and optional token. return `:ok` or `true` to allow it, and an error to reject it. if authentication needs slow network io, put that work behind a bounded service instead of letting connection processes wait forever.

a durable foreign publish is stored with the configured storage adapter before delivery. ephemeral publishes are not stored.

## topics and payloads

topic strings use the same names as `Wiregrid.Chat`.

| text | runtime topic |
| --- | --- |
| `general` or `channel:general` | `{:channel, "general"}` |
| `thread:42` | `{:thread, "42"}` |
| `room:lobby` | `{:room, "lobby"}` |
| `user:ada` | `{:user, "ada"}` |
| `channel:i:7` | `{:channel, 7}` |
| `custom:ops:desk` | `{:custom, "ops", "desk"}` |

`join_room` takes the room id as a plain string, so `lobby` is the same room an elixir caller joins with `"lobby"`.

`application/json` bodies are decoded into the chat event shape (`type`, `body`, `message_id`, and the other chat fields). anything else stays bytes and is delivered as `%{type: :foreign, payload: ..., content_type: ...}`. events produced by elixir are encoded as json on the way out, so a c or browser client can read a normal `say`.

`history` pages that same stream after the session passes the `:read` authorizer check. the payload is json `{"events":[...]}` and the next cursor is its own field. the c call is `wg_history`.

## c client

build and test it with:

```sh
make -C native/c
make -C native/c test
```

cmake builds static/shared libraries and installs pkg-config metadata too.

## installed files

from a checkout, `scripts/install.sh` builds the same library and copies it onto a prefix, along with the browser kit and the source bindings. `share/wiregrid/LAYOUT` in that prefix is the plain-text map.

| path | what it is |
| --- | --- |
| `include/wiregrid.h` | c header |
| `lib/libwiregrid.a` | static library |
| `lib/libwiregrid.so` or `lib/libwiregrid.dylib` | shared library |
| `lib/pkgconfig/wiregrid.pc` | pkg-config file |
| `share/wiregrid/ui` | browser html, css, and javascript |
| `share/wiregrid/bindings` | gleam, lfe, and erlang sources |

on a linux system that keeps libraries in `lib64`, `/usr` and `/usr/local` receive the libraries there. other prefixes use `lib`.

after the script prints its environment lines, or immediately when the prefix is already on the default search path:

```sh
pkg-config --exists wiregrid
cc -o chat chat.c $(pkg-config --cflags --libs wiregrid)
```

`share/wiregrid/bindings` holds source. compile those files from the application that wants them on the code path. elixir stays a mix dependency of the application that runs the node, and mix compiles the beam files there.

## release tarball

a `v*` tag publishes `wiregrid-<version>-linux-x86_64.tar.gz` and `SHA256SUMS` on the github release. the install script checks that sha256 when the checksums file is attached.

```sh
curl -fsSL https://raw.githubusercontent.com/Plainwire-development/Wiregrid/v1.0.0/scripts/install.sh | sh
```

`WIREGRID_TARBALL` installs an archive already on disk. a checkout with `native/c` builds the library on this machine.

c abi major `1` speaks foreign protocol `1`. wrappers should query/check those versions instead of assuming a later major will still fit.

there is no hidden background thread or event loop. one owner drives a client handle at a time. a runtime that wants concurrent use should serialize access to one handle or give separate workers their own handles.

while a synchronous request is waiting for its response, asynchronous deliveries are queued in a bounded native queue. if that queue fills, the client closes the connection and returns `WG_ERR_OVERFLOW`. continuing after silently dropping one delivery would make acknowledgement state ambiguous, so overflow is treated as a broken stream.

current socket code targets posix systems such as linux and macos. the public abi is kept separate from that backend so a windows transport can be added without changing the basic client model.

## wrapping it from another language

a normal wrapper only needs to expose:

- connect and close
- subscribe and unsubscribe
- publish bytes plus a content type
- acknowledge a delivery
- set presence
- join and leave a room
- poll events
- inspect abi/protocol versions and errors

keep the c structs private to the wrapper. own the native handle inside one object, copy event bytes into the target runtime before calling `wg_event_free`, and make close safe to call more than once.

rust and zig can wrap the c abi directly. go can use cgo. python can use cffi or ctypes. java can use jni/jna/panama and dotnet can use p/invoke. a future native implementation in any of those languages can also speak the same wire protocol directly.
