export * from "./js/core.js";
export * from "./js/chat.js";
export * from "./js/composer.js";
export { bindComposer as mountComposer } from "./js/composer.js";
export * from "./js/overlays.js";
export * from "./js/liveview.js";
export * from "./js/client.js";
export * from "./js/timeline.js";
export * from "./js/mount.js";

import {
  version,
  createStore,
  setTheme,
  restoreTheme,
  setDensity,
} from "./js/core.js";
import {
  appendMessage,
  upsertMessage,
  bindChatActions,
  renderMessage,
  jumpToMessage,
} from "./js/chat.js";
import { bindComposer } from "./js/composer.js";
import { createOverlay, bindTabs } from "./js/overlays.js";
import { WiregridHooks } from "./js/liveview.js";
import { connectChat } from "./js/client.js";
import { createTimeline } from "./js/timeline.js";
import { mountChat } from "./js/mount.js";

const wiregrid = {
  version,
  createStore,
  setTheme,
  restoreTheme,
  setDensity,
  appendMessage,
  upsertMessage,
  bindChatActions,
  renderMessage,
  jumpToMessage,
  bindComposer,
  mountComposer: bindComposer,
  createOverlay,
  bindTabs,
  WiregridHooks,
  connectChat,
  createTimeline,
  mountChat,
};

export default wiregrid;
