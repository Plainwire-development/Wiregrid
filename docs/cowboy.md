# cowboy websocket adapter

`Wiregrid.Transport.Cowboy` is optional. the host application supplies cowboy; wiregrid does not make it a core dependency.

authentication happens before the websocket is upgraded. the wiregrid session is created from `websocket_init/1`, so the cowboy process is also the session owner.

wiregrid passes `max_frame_size` and `idle_timeout` into cowboy so oversized frames can be rejected before protocol decode.

browser origins are deny-by-default when an `Origin` header is present unless the origin is listed in `origin_allowlist`.

## acknowledgements

`ack_strategy: :client` is the normal production choice. the client explicitly acknowledges a delivery, which means slow network/client behavior remains visible to wiregrid backpressure.

`ack_strategy: :transport` is for trusted/internal transports. it acknowledges only after the websocket process has consumed and successfully encoded the delivery.

## rate limiting

pre-auth attempts use a fixed-window limiter by default. authenticated frames use a token bucket by default so fixed-window boundary bursts are smoothed out.

see `rate-limiting.md` for the related options.

## application commands

`Wiregrid.Transport.Command` handles the transport-neutral command routing. built-in wiregrid commands are handled first.

set `command_handler:` when the app needs extra commands. it can be a two-argument function or a module with `handle_command/2`.

custom handlers only receive unknown commands plus a sanitized context containing `instance`, `session_id`, and `user_id`. auth headers, resume tokens, and cowboy request internals are not passed through.

command values are bounded and checked before the extension runs. extension crashes fail closed as `{:error, :command_handler_failed}`.

lfe apps can use `wiregrid_macros:defcompiled-command-handler` for a fixed command grammar.

## replay command

authenticated transports may issue `{:replay, stream, opts}`. the transport router binds that command to the current session; the client cannot choose another session id.
