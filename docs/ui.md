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

user message strings are inserted with `textContent`. wiregrid intentionally does not have a helper that accepts arbitrary html from a message body. if the app supports markdown, render and sanitize it in the app's own trusted markdown pipeline.

## browser socket

`js/client.js` exports `connectChat`. it speaks `Wiregrid.Transport.Protocol.JSON` over a websocket, using the same topic strings as the c gateway. point cowboy at that protocol and send text frames.

`chat.html` is a static shell for the css. open it from a static file server next to `wiregrid.css`. add `?socket=ws://127.0.0.1:PORT/chat` when a json websocket is actually listening. the page subscribes to `general`, appends messages with `textContent`, and acks deliveries.

## liveview

`js/liveview.js` exports `WiregridHooks`. the hooks cover the composer and delegated message actions and use `pushEvent` for communication. they do not create another socket or another client-side copy of the server state.

## long histories

message rows use `content-visibility` where browsers support it, and the timeline helpers put a ceiling on retained dom nodes.

that is enough for normal chat history. if a screen is expected to keep tens or hundreds of thousands of rows mounted, use the ui pieces with a real virtualization/windowing library instead of asking the browser to keep the entire history in the dom.

## accessibility

interactive components use normal focusable elements and aria state where the helper owns the behavior. reduced-motion preferences are respected by the motion layer.

if you build a custom dom shape around the css only, the app still owns labels, focus order, live regions, keyboard actions, and screen-reader behavior for that custom markup.
