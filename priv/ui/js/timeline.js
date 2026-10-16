import { renderMessage } from "./chat.js";
import { clamp } from "./core.js";

// Owns its message nodes. Indexes make append, upsert and eviction independent
// of retained history size; callers can leave separators beside the messages.
export function createTimeline(container, options = {}) {
  const max = clamp(Math.floor(Number(options.maxMessages) || 2000), 1, 20000);
  const messages = new Map();
  const nonces = new Map();
  let destroyed = false;
  const previousRole = container.getAttribute("role");
  const previousLive = container.getAttribute("aria-live");
  if (previousRole == null) container.setAttribute("role", "log");
  if (previousLive == null) container.setAttribute("aria-live", "polite");

  function forget(id, node) {
    messages.delete(id);
    if (node.dataset.wgNonce != null && nonces.get(node.dataset.wgNonce) === id)
      nonces.delete(node.dataset.wgNonce);
  }
  function remember(node) {
    const id = node.dataset.messageId;
    messages.set(id, node);
    if (node.dataset.wgNonce != null) nonces.set(node.dataset.wgNonce, id);
  }
  function trim() {
    while (messages.size > max) {
      const [id, node] = messages.entries().next().value;
      forget(id, node);
      node.remove();
    }
  }
  for (const node of container.querySelectorAll(".wg-message[data-message-id]")) {
    const old = messages.get(node.dataset.messageId);
    if (old) { forget(node.dataset.messageId, old); old.remove(); }
    remember(node);
  }
  trim();

  function upsert(message) {
    if (destroyed) throw new Error("Wiregrid timeline was destroyed");
    const id = message.id == null ? null : String(message.id);
    const nonce = message.nonce == null ? null : String(message.nonce);
    const oldId = (id != null && messages.has(id)) ? id : nonces.get(nonce);
    const old = messages.get(oldId);
    const optimisticId = nonces.get(nonce);
    if (optimisticId != null && optimisticId !== oldId) {
      const duplicate = messages.get(optimisticId);
      forget(optimisticId, duplicate);
      duplicate.remove();
    }
    const atBottom = container.scrollHeight - container.scrollTop - container.clientHeight <= 48;
    const node = renderMessage(message, options);
    if (old) {
      // Replacing an item must preserve its place in both DOM and eviction order.
      if (oldId === node.dataset.messageId) {
        if (old.dataset.wgNonce != null) nonces.delete(old.dataset.wgNonce);
        messages.set(oldId, node);
        if (nonce != null) nonces.set(nonce, oldId);
      } else {
        const entries = [...messages];
        forget(oldId, old);
        messages.clear();
        for (const [key, value] of entries) {
          if (key === oldId) remember(node);
          else messages.set(key, value);
        }
        if (nonce != null) nonces.set(nonce, node.dataset.messageId);
      }
      old.replaceWith(node);
    } else {
      container.append(node);
      remember(node);
    }
    trim();
    if (options.autoScroll !== false && atBottom) container.scrollTop = container.scrollHeight;
    return node;
  }

  return {
    append: upsert,
    upsert,
    get size() { return messages.size; },
    get: (id) => messages.get(String(id)) ?? null,
    remove(id) {
      const key = String(id), node = messages.get(key);
      if (!node) return false;
      forget(key, node);
      node.remove();
      return true;
    },
    clear() {
      for (const node of messages.values()) node.remove();
      messages.clear();
      nonces.clear();
    },
    destroy() {
      destroyed = true;
      messages.clear();
      nonces.clear();
      if (previousRole == null) container.removeAttribute("role");
      if (previousLive == null) container.removeAttribute("aria-live");
    },
  };
}
