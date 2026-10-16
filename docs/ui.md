# ui

wiregrid ui is a chat-oriented css and javascript package. it is not a frontend framework and it does not own your socket, store, router, or message model.

it mostly exists so every wiregrid app does not have to rebuild the same channel list, message row, composer, reaction bar, thread panel, call controls, dialogs, and dark theme from scratch.

## installing it

```sh
mix wiregrid.ui.install
```

that copies the ui package into `priv/static/vendor/wiregrid` by default.

if you are using it like a package, `wiregrid.css` is the full stylesheet and `wiregrid.esm.js` exports the complete browser api.

## installed copy

`scripts/install.sh` also copies this package to `share/wiregrid/ui` under the install prefix. a static page can load `wiregrid.css` and `wiregrid.js` from that directory. a bundler can import `wiregrid.esm.js` from the same place. the classes, tokens, and helpers match `priv/ui`.

## css layout

there are seven layers:

1. `tokens.css`
2. `base.css`
3. `layout.css`
4. `components.css`
5. `chat.css`
6. `utilities.css`
7. `motion.css`

use the full bundle when you want sensible defaults:

```css
@import "./wiregrid/wiregrid.css";
```

import the layers yourself when the app already has a reset, utility library, or component system.

all public classes start with `wg-`. utility classes use `wg-u-`, so wiregrid can live beside tailwind or another utility set without taking names like `flex`, `grid`, or `hidden`.

## changing the look

most styling comes from semantic css variables. override those before copying component rules.

```css
:root {
  --wg-bg: #0b0d12;
  --wg-panel: #11151d;
  --wg-text: #f6f7fb;
  --wg-accent: #886cff;
  --wg-sidebar: 290px;
  --wg-message-gap: 6px;
  --wg-r-3: 14px;
}
```

stock themes use `data-wg-theme="dark"` and `data-wg-theme="light"`. density uses `data-wg-density="compact"`, `comfortable`, or `cozy`.

optional presets such as `midnight`, `soft`, and `plainwire` are separate files. they are examples of a finished look, not a required skin.

for a real product, it is usually better to define one small brand file that changes tokens and only add custom component css where the product actually needs a different shape.

## what is included

chat pieces include channel and member lists, normal and compact messages, replies, reactions, attachments, embeds, code blocks, polls, uploads, unread and date separators, typing state, threads, inbox rows, presence, voice tiles, call stages, connection state, and composers.

normal app pieces include buttons, inputs, menus, listboxes, tabs, dialogs, banners, switches, segmented controls, cards, skeletons, progress, tooltips, popovers, and toasts.

these are class-level building blocks. wiregrid does not force one generated dom tree on the app.

## javascript helpers

the complete panel is optional too. give its parent a height, import the css, then mount it:

```html
<div id="chat" style="height: 600px"></div>
```

```js
import { mountChat } from "./wiregrid/wiregrid.esm.js";

const chat = mountChat(document.querySelector("#chat"), {
  url: "wss://your-app.example/chat",
  topic: "general",
  maxMessages: 500,
  maxBytes: 65536,
  onError(error) { console.error("chat request failed", error); }
});
await chat.ready;
// Call chat.destroy() when the page or framework component unmounts.
```

this creates a labeled panel, connection status, scrollable message log, and composer. it waits for a session and subscription before enabling send, acknowledges received deliveries, and deduplicates message events by their server event id. channel aliases such as `channel:general` work too. it renders ordinary `message` events; provide `mapMessage(envelope)` for an application-specific view, or return `null` to omit an event. the app still supplies trusted author display data and owns edit/delete/reaction projections. it does not automatically fetch history or reconnect; `chat.client` exposes the socket commands and `chat.timeline` exposes the retained rows.

```js
import {
  appendMessage,
  bindChatActions,
  bindComposer,
  createOverlay,
  createStore,
  setTheme
} from "./wiregrid/wiregrid.esm.js";
```

`appendMessage` and `upsertMessage` keep retained message nodes bounded by default. `bindComposer` handles enter-to-send, textarea growth, and a utf-8 byte limit. `createOverlay` manages focus and restores it on close. tabs and menus have keyboard behavior.

for high message volumes, use `createTimeline(container, {maxMessages: 2000})`. it indexes ids and nonces, so appending, replacing a known id, and evicting the oldest row do not scan the retained dom. it owns its message nodes and exposes `append`, `upsert`, `get`, `remove`, `clear`, `size`, and `destroy`. an optimistic row with a `nonce` is reconciled when a server row carries that nonce. changing an optimistic id rebuilds the small retained index once to preserve display and eviction order. scrolling follows new messages only when the reader is already near the bottom. `autoScroll: false` disables that behavior.

both the esm and global composers await `onSubmit`, prevent duplicate sends, preserve failed drafts, and keep text typed while a send is in flight. returning `false` keeps the submitted text too. use `onError(error, {form, textarea})` to show failures; without it, the form emits a bubbling `wiregrid:error` event. call `destroy` before replacing a form. modified enter and ime composition do not send a message.

the esm entry point and individual modules include typescript declarations. `mountComposer` is an alias of `bindComposer` on the esm entry point; the classic global bundle keeps its smaller compatibility api.

user message strings are inserted with `textContent`. wiregrid intentionally does not have a helper that accepts arbitrary html from a message body. if the app supports markdown, render and sanitize it in the app's own trusted markdown pipeline.

## browser socket

`js/client.js` exports `connectChat`. it speaks `Wiregrid.Transport.Protocol.JSON` over a websocket, using the same topic strings as the c gateway. point cowboy at that protocol and send text frames.

`client.ready` resolves with the server's `ready` message after the authenticated session exists. commands queued before that message count toward the pending limit. the browser receives binary json frames as array buffers as well as text frames. `subscribe`, `unsubscribe`, `say`, `publish`, `history`, `ack`, `presence`, `joinRoom`, `leaveRoom`, and `ping` return promises. failed responses reject with the server response; socket, deadline, and local admission failures reject with an `Error`.

| option | default | purpose |
| --- | ---: | --- |
| `connectTimeoutMs` | 10000 | deadline for the session ready message |
| `requestTimeoutMs` | 10000 | total command deadline, including waiting for readiness |
| `maxPending` | 256 | maximum queued and outstanding requests |
| `maxBufferedBytes` | 1048576 | maximum single request and combined unsent command/websocket bytes |

these options are positive integers. callers can inspect `pendingRequests` and supply `onError` and `onDebug`. debug events contain only a fixed event name, operation, and pending count; they omit urls, tokens, topics and message content. `close()` rejects pending work immediately. callbacks may return promises; rejected callbacks are sent to `onError`. requests are never automatically retried because a timed-out publish may already have been persisted.

native browser websockets do not let javascript set an authorization header. configure a same-origin session/cookie-aware `auth_fun` or your application's authenticated websocket proxy, plus an explicit `origin_allowlist`; the built-in bearer-header mode is for clients that can set headers. the library does not put credentials into urls.

`chat.html` is a static shell for the css. open it from a static file server next to `wiregrid.css`. add `?socket=ws://127.0.0.1:PORT/chat` when a json websocket is actually listening. the page subscribes to `general`, appends messages with `textContent`, and acks deliveries.

## liveview

`js/liveview.js` exports `WiregridHooks`. the hooks cover the composer and delegated message actions and use `pushEvent` for communication. they do not create another socket or another client-side copy of the server state.

## long histories

message rows use `content-visibility` where browsers support it, and the timeline helpers put a ceiling on retained dom nodes.

that is enough for normal chat history. if a screen is expected to keep tens or hundreds of thousands of rows mounted, use the ui pieces with a real virtualization/windowing library instead of asking the browser to keep the entire history in the dom.

maintainers run the dom regressions and typed consumer checks with node 24+:

```sh
npm ci --prefix test/ui
npm --prefix test/ui test
```

these dependencies live under `test/ui`; the shipped browser package has no runtime dependencies.

## accessibility

interactive components use normal focusable elements and aria state where the helper owns the behavior. reduced-motion preferences are respected by the motion layer.

if you build a custom dom shape around the css only, the app still owns labels, focus order, live regions, keyboard actions, and screen-reader behavior for that custom markup.
