import ui, {
  bindComposer, connectChat, createTimeline, mountChat, mountComposer,
  type ChatEnvelope, type Message,
} from "../../priv/ui/wiregrid.esm.js";
import { connectChat as connectDirect } from "../../priv/ui/js/client.js";
import { createTimeline as timelineDirect } from "../../priv/ui/js/timeline.js";

const root = document.createElement("div");
const form = document.createElement("form");
connectDirect("ws://chat").close();
timelineDirect(root).destroy();
const client = connectChat("wss://chat.example/chat", {
  maxPending: 32,
  onDebug: ({ event, pending }) => console.debug(event, pending),
  onEvent: async (event) => { await client.ack(event.delivery_id); },
});
const timeline = createTimeline(root, { maxMessages: 500, actions: ["reply"], autoScroll: false });
const message: Message = { id: "one", nonce: "local-one", body: "hello" };
timeline.upsert(message);
timeline.get(message.id)?.focus();
const composer = bindComposer(form, {
  onSubmit: (body, { textarea }) => { textarea.focus(); return client.say("general", body); },
  onError: (error, { form }) => { console.error(error, form); },
});
mountComposer(form, {});
const chat = mountChat(root, {
  url: new URL("wss://chat.example/chat"), topic: "general",
  mapMessage: (event: ChatEnvelope) => ({ id: event.event_id ?? event.delivery_id, body: String(event.event.body) }),
});
ui.mountChat(root, { url: "wss://chat.example/chat", topic: "general" });
void composer.submit();
chat.destroy();

// @ts-expect-error request limits must be numbers
connectChat("ws://chat", { maxPending: "unbounded" });
// @ts-expect-error message callbacks must receive an envelope
mountChat(root, { url: "ws://chat", topic: "general", mapMessage: (_event: string) => message });
