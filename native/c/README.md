# libwiregrid

`libwiregrid` is the small c client for `Wiregrid.Foreign.Gateway`.

it is a normal socket library. it does not load the beam, use nifs, or expose erlang terms. that keeps the vm boundary simple and makes the same abi usable from rust, zig, go/cgo, python cffi/ctypes, jni/jna/panama, p/invoke, and similar runtimes.

## build

```sh
make
make test
```

or with cmake:

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
cmake --install build
```

the cmake install includes `wiregrid.h`, shared/static libraries, and `wiregrid.pc`.

## install

from the repository root, `scripts/install.sh` builds this library and installs the header, the static library, the shared library, and `wiregrid.pc`. a published tag ships `wiregrid-<version>-linux-x86_64.tar.gz` and `SHA256SUMS`. the script checks that sha256 when the checksums file is attached.

```sh
curl -fsSL https://raw.githubusercontent.com/Plainwire-development/Wiregrid/v1.0.0/scripts/install.sh | sh
```

`docs/foreign-clients.md` lists the prefix layout and the `pkg-config` compile line. the same script copies the browser kit to `share/wiregrid/ui`.

## connect

```c
wg_client_options opts;
wg_client_options_init(&opts);
opts.auth_token = getenv("WIREGRID_TOKEN");

wg_client *client = NULL;
char error[256];
int rc = wg_connect_ex("127.0.0.1", 9567, "alice", &opts, &client,
                       error, sizeof(error));
if (rc != WG_OK) {
    fprintf(stderr, "wiregrid: %s\n", error[0] ? error : wg_result_string(rc));
}
```

a client handle is single-owner. if several threads/tasks need the same connection, put a mutex/serializer around it, or keep one client per event-loop worker.

synchronous requests can receive async deliveries while they wait for the matching response. those deliveries go into a bounded native queue and are returned by `wg_poll`.

if that queue fills, the socket is closed and the call returns `WG_ERR_OVERFLOW`. silently dropping an event and continuing would make delivery/ack state unclear, so overflow breaks the stream instead.

payloads are bytes. content type is a separate field. `general` is the chat channel `{:channel, "general"}`. send `application/json` when the payload is a chat event such as `{"type":"message","body":"hello"}`. `wg_history` asks for one authorized page and writes the json body into a caller buffer.

connect uses the client timeout for the tcp handshake as well as later reads. a protocol mismatch closes the socket.

request deadlines cover the whole exchange, including writes and intervening events. timeout or malformed input closes the stream; a publish may already have committed, so automatic retries can duplicate it. dns lookup uses the system resolver and is synchronous. `wg_poll` keeps partial frames across timeouts and supports nonblocking calls with a zero timeout.

abi minor 2 exposes `wg_client_fd` (a borrowed descriptor) and `wg_pending_events` for poll/select integration. drain queued events first, and never read, close or change flags on the descriptor yourself. `wg_history` accepts a maximum page size of 100 and reports undersized output buffers with `WG_ERR_OVERFLOW`; grow the buffers and retry the same cursor. the connection stays usable and cursors are never truncated.

`make test` runs the normal protocol exchange and fourteen hostile-peer regressions covering fragmented packets, nonblocking polls, trickled responses, event floods, malformed frames, final responses before eof, and history buffer sizing.

## compatibility

wrappers should check `WG_ABI_MAJOR` and `WG_PROTOCOL_VERSION`.

new minor functions can be added without changing the abi major. an incompatible struct or calling-convention change needs a new major.
