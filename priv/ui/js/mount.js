import { text } from "./core.js";
import { connectChat } from "./client.js";
import { bindComposer } from "./composer.js";
import { createTimeline } from "./timeline.js";

function topicKey(topic) {
  const [kind, ...parts] = topic.split(":");
  if (!["channel", "thread", "room", "user", "game", "document", "custom"].includes(kind) || !parts.length)
    return `channel:${topic}`;
  if (kind !== "custom" && parts[0] === "i" && /^\d+$/.test(parts[1] ?? ""))
    return `${kind}:i:${BigInt(parts[1])}`;
  return topic;
}

export function mountChat(root, options = {}) {
  if (!options.url || !options.topic) throw new Error("Wiregrid chat requires url and topic");
  const topic = topicKey(options.topic);
  let destroyed = false;
  const panel = text("section", "", "wg-chat");
  panel.setAttribute("aria-label", options.label ?? `Chat: ${options.topic}`);
  const header = text("header", options.label ?? options.topic, "wg-header wg-title");
  const status = text("div", "Connecting…", "wg-connection-banner");
  status.setAttribute("role", "status");
  status.dataset.state = "connecting";
  const messages = text("div", "", "wg-messages wg-chat__messages");
  messages.tabIndex = 0;
  messages.setAttribute("aria-label", "Messages");
  const form = text("form", "", "wg-composer-wrap");
  const field = text("div", "", "wg-composer");
  const textarea = document.createElement("textarea");
  textarea.rows = 1;
  textarea.placeholder = options.placeholder ?? "Write a message…";
  textarea.setAttribute("aria-label", options.composerLabel ?? "Message");
  const send = text("button", options.sendLabel ?? "Send", "wg-button wg-button--primary");
  send.type = "submit";
  const count = text("span", "", "wg-muted");
  count.dataset.wgByteCount = "";
  field.append(textarea, send, count);
  form.append(field);
  panel.append(header, status, messages, form);
  root.append(panel);
  const timeline = createTimeline(messages, { ...options, actions: options.actions ?? false });

  function connected(active) {
    textarea.disabled = send.disabled = !active;
    status.dataset.state = active ? "online" : "offline";
    status.textContent = active ? "Connected" : "Disconnected";
  }
  function report(error) {
    if (destroyed) return;
    status.dataset.state = "error";
    status.textContent = "Unable to complete the request. Try again.";
    const emit = (detail) => root.dispatchEvent(new CustomEvent("wiregrid:error", { detail, bubbles: true }));
    try {
      if (options.onError) Promise.resolve(options.onError(error)).catch(emit);
      else emit(error);
    } catch (handlerError) { emit(handlerError); }
  }
  textarea.disabled = send.disabled = true;
  let client;
  try {
    client = connectChat(options.url, {
      ...options,
      onReady: undefined,
      onError: report,
      onClose(event) {
        if (!destroyed) { connected(false); return options.onClose?.(event); }
      },
      async onEvent(envelope) {
        if (destroyed) return;
        try {
          if (topicKey(envelope.topic) === topic) {
            const event = envelope.event;
            const message = options.mapMessage ? options.mapMessage(envelope) :
              event?.type === "message" ? { ...event, id: envelope.event_id || envelope.delivery_id } : null;
            if (message) timeline.upsert(message);
            await options.onEvent?.(envelope);
          }
          if (envelope.delivery_id) await client.ack(envelope.delivery_id);
        } catch (error) { return report(error); }
      },
    });
  } catch (error) {
    timeline.destroy();
    panel.remove();
    throw error;
  }
  const ready = client.ready.then(async (message) => {
    if (destroyed) return;
    await client.subscribe(options.topic);
    if (!destroyed) { connected(true); await options.onReady?.(message); }
    return message;
  });
  ready.catch(report);
  const composer = bindComposer(form, {
    maxBytes: options.maxBytes,
    enterToSend: options.enterToSend,
    onError: report,
    async onSubmit(body) {
      await ready;
      await client.say(options.topic, body);
      if (!destroyed) connected(true);
    },
  });
  return {
    client, timeline, composer, ready,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      composer.destroy();
      timeline.destroy();
      client.close();
      panel.remove();
    },
  };
}
