import assert from "node:assert/strict";
import { test, beforeEach, afterEach } from "node:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { parseHTML } from "linkedom";
import { connectChat } from "../../priv/ui/js/client.js";
import { bindComposer } from "../../priv/ui/js/composer.js";
import { renderMessage, reconcileOptimistic } from "../../priv/ui/js/chat.js";
import { createTimeline } from "../../priv/ui/js/timeline.js";
import { mountChat } from "../../priv/ui/js/mount.js";
import { WiregridHooks } from "../../priv/ui/js/liveview.js";

class Socket {
  static OPEN = 1;
  static all = [];
  constructor() {
    this.readyState = 0;
    this.bufferedAmount = 0;
    this.listeners = new Map();
    this.sent = [];
    Socket.all.push(this);
  }
  addEventListener(name, fn) {
    if (!this.listeners.has(name)) this.listeners.set(name, []);
    this.listeners.get(name).push(fn);
  }
  emit(name, event = {}) { for (const fn of this.listeners.get(name) ?? []) fn(event); }
  open() { this.readyState = 1; this.emit("open"); }
  message(message, binary = false) {
    const json = JSON.stringify(message);
    this.emit("message", { data: binary ? new TextEncoder().encode(json).buffer : json });
  }
  send(data) {
    if (this.sendError) throw this.sendError;
    this.sent.push(JSON.parse(data));
  }
  close() { if (this.readyState === 3) return; this.readyState = 3; this.emit("close"); }
  ready() { this.open(); this.message({ type: "ready", session_id: "s1", restored: {} }, true); }
  reply(message = {}) {
    const request = this.sent.at(-1);
    this.message({ type: "response", id: request.id, ok: true, ...message });
  }
}

const originalSocket = globalThis.WebSocket;
const originalDocument = globalThis.document;
const originalCustomEvent = globalThis.CustomEvent;
const originalCSS = globalThis.CSS;
beforeEach(() => {
  Socket.all = [];
  globalThis.WebSocket = Socket;
  const window = parseHTML("<!doctype html><html><body></body></html>");
  globalThis.document = window.document;
  globalThis.CustomEvent = window.CustomEvent;
  globalThis.CSS = { escape: (value) => value };
});
afterEach(() => {
  for (const socket of Socket.all) socket.close();
  globalThis.WebSocket = originalSocket;
  globalThis.document = originalDocument;
  globalThis.CustomEvent = originalCustomEvent;
  globalThis.CSS = originalCSS;
});
const tick = () => new Promise(setImmediate);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
};

test("binary JSON handshake gates queued commands until the session is ready", async () => {
  const client = connectChat("ws://chat");
  const socket = Socket.all.at(-1);
  const subscribed = client.subscribe("general");
  socket.open();
  assert.equal(socket.sent.length, 0);
  socket.ready();
  assert.equal((await client.ready).session_id, "s1");
  assert.equal(socket.binaryType, "arraybuffer");
  assert.equal(socket.sent[0].topic, "general");
  socket.reply();
  await subscribed;
  assert.equal(client.pendingRequests, 0);
});

test("pending work is bounded even before the handshake and request timeouts free slots", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const client = connectChat("ws://chat", { maxPending: 1, requestTimeoutMs: 20 });
  const pending = assert.rejects(client.subscribe("general"), /timed out/);
  await assert.rejects(client.subscribe("other"), /too many pending/);
  t.mock.timers.tick(20);
  await pending;
  assert.equal(client.pendingRequests, 0);
  Socket.all.at(-1).ready();
  assert.equal(Socket.all.at(-1).sent.length, 0);
});

test("an open TCP websocket without a ready frame still has a handshake deadline", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const errors = [];
  const client = connectChat("ws://chat", { connectTimeoutMs: 20, onError: (e) => errors.push(e) });
  const ready = assert.rejects(client.ready, /connection timed out/);
  const pending = assert.rejects(client.subscribe("general"), /connection timed out/);
  Socket.all.at(-1).open();
  t.mock.timers.tick(20);
  await Promise.all([ready, pending]);
  assert.equal(Socket.all.at(-1).readyState, 3);
  assert.equal(client.pendingRequests, 0);
  assert.equal(errors.length, 1);
});

test("send exceptions, socket backpressure and oversized UTF-8 messages release request slots", async () => {
  const client = connectChat("ws://chat", { maxBufferedBytes: 300 });
  const socket = Socket.all.at(-1);
  socket.ready();
  socket.sendError = new Error("send failed");
  await assert.rejects(client.subscribe("general"), /send failed/);
  socket.sendError = null;
  socket.bufferedAmount = 299;
  await assert.rejects(client.subscribe("general"), /backpressure/);
  socket.bufferedAmount = 0;
  await assert.rejects(client.say("general", "😀".repeat(100)), /too large/);
  assert.equal(client.pendingRequests, 0);
  assert.equal(socket.sent.length, 0);
});

test("closing before readiness rejects queued work and future requests immediately", async () => {
  const client = connectChat("ws://chat");
  const pending = assert.rejects(client.subscribe("general"), /closed/);
  client.close();
  await pending;
  await assert.rejects(client.ready, /closed/);
  await assert.rejects(client.ping(), /closed/);
  assert.equal(client.pendingRequests, 0);
});

test("commands queued before readiness share a byte budget", async () => {
  const client = connectChat("ws://chat", { maxBufferedBytes: 100 });
  const first = assert.rejects(client.subscribe("a".repeat(20)), /closed/);
  await assert.rejects(client.subscribe("b".repeat(20)), /backpressure/);
  assert.equal(client.pendingRequests, 1);
  client.close();
  await first;
});

test("request routing cannot be overwritten and remote failures propagate", async () => {
  const debug = [];
  const client = connectChat("ws://chat", { onDebug: (event) => debug.push(event) });
  const socket = Socket.all.at(-1);
  socket.ready();
  const request = client.publish("general", { body: "secret" }, { op: "unsubscribe", id: 99 });
  assert.equal(socket.sent.at(-1).op, "publish");
  assert.notEqual(socket.sent.at(-1).id, 99);
  const rejected = assert.rejects(request, (e) => e.error === "unauthorized");
  socket.reply({ ok: false, error: "unauthorized" });
  await rejected;
  assert.equal(JSON.stringify(debug).includes("secret"), false);
});

test("invalid server values and rejected consumer callbacks reach onError without breaking requests", async () => {
  const errors = [];
  const client = connectChat("ws://chat", {
    onError: (error) => errors.push(error),
    onEvent: async () => { throw new Error("consumer failed"); },
  });
  const socket = Socket.all.at(-1);
  socket.ready();
  socket.message(null);
  socket.message({ type: "event" });
  await tick();
  const request = client.ping();
  socket.reply({ pong: "hello" });
  assert.equal((await request).pong, "hello");
  assert.equal(errors.length, 2);
});

function composerForm() {
  const form = document.createElement("form");
  form.append(document.createElement("textarea"));
  document.body.append(form);
  return form;
}
for (const mode of ["module", "global"]) {
  function bind(form, options) {
    if (mode === "module") return bindComposer(form, options);
    const scope = { document, TextEncoder, CustomEvent };
    vm.runInNewContext(readFileSync(new URL("../../priv/ui/wiregrid.js", import.meta.url), "utf8"), scope);
    return scope.WiregridUI.mountComposer(form, options);
  }
  test(`${mode} composer preserves a draft after rejection and prevents concurrent sends`, async () => {
    const form = composerForm(), textarea = form.querySelector("textarea");
    const sent = deferred(), errors = [];
    let calls = 0;
    const composer = bind(form, { onSubmit: () => { calls++; return sent.promise; }, onError: (e) => errors.push(e) });
    textarea.value = "keep my draft";
    const result = composer.submit();
    await composer.submit();
    assert.equal(calls, 1);
    sent.reject(new Error("offline"));
    assert.equal(await result, false);
    assert.equal(textarea.value, "keep my draft");
    assert.equal(form.dataset.submitting, undefined);
    assert.equal(errors.length, 1);
    composer.destroy();
  });
  test(`${mode} composer keeps text typed during an in-flight send`, async () => {
    const form = composerForm(), textarea = form.querySelector("textarea");
    const sent = deferred();
    const composer = bind(form, { onSubmit: () => sent.promise });
    textarea.value = "first";
    const result = composer.submit();
    textarea.value = "next draft";
    textarea.dispatchEvent(new CustomEvent("input"));
    sent.resolve();
    await result;
    assert.equal(textarea.value, "next draft");
    composer.destroy();
  });
  test(`${mode} composer measures bytes and ignores modified Enter and IME`, async () => {
    const form = composerForm(), textarea = form.querySelector("textarea");
    let calls = 0;
    const composer = bind(form, { maxBytes: 3, onSubmit: () => { calls++; } });
    textarea.value = "😀";
    await composer.submit();
    assert.equal(calls, 0);
    textarea.value = "hi";
    for (const fields of [{ ctrlKey: true }, { metaKey: true }, { altKey: true }, { isComposing: true }]) {
      const event = new CustomEvent("keydown", { cancelable: true });
      Object.assign(event, { key: "Enter", ...fields });
      textarea.dispatchEvent(event);
      assert.equal(event.defaultPrevented, false);
    }
    assert.equal(calls, 0);
    composer.destroy();
  });
}

test("message rendering escapes hostile text and optimistic replacement honors retention", () => {
  const container = document.createElement("div");
  const node = renderMessage({ id: 1, nonce: "n1", body: "<script>alert(1)</script>" });
  container.append(node);
  assert.equal(container.querySelector("script"), null);
  assert.equal(node.dataset.wgNonce, "n1");
  reconcileOptimistic(container, "n1", { id: 2, body: "accepted" }, { maxMessages: 1 });
  reconcileOptimistic(container, "missing", { id: 3, body: "newer" }, { maxMessages: 1 });
  assert.equal(container.querySelectorAll(".wg-message").length, 1);
  assert.equal(container.firstElementChild.dataset.messageId, "3");
});

test("indexed timeline deduplicates, reconciles nonces, bounds nodes and preserves eviction order", () => {
  const container = document.createElement("div");
  const timeline = createTimeline(container, { maxMessages: 3, actions: false });
  timeline.append({ id: 1, body: "first" });
  timeline.append({ id: "pending", nonce: "n1", body: "sending" });
  timeline.append({ id: 3 });
  timeline.upsert({ id: 2, nonce: "n1", body: "sent" });
  timeline.upsert({ id: 1, body: "edited" });
  assert.equal(timeline.size, 3);
  assert.equal(timeline.get("pending"), null);
  assert.equal(timeline.get(2).querySelector(".wg-message-body").textContent, "sent");
  timeline.append({ id: 4 });
  assert.equal(timeline.get(1), null);
  assert.deepEqual([...container.children].map((n) => n.dataset.messageId), ["2", "3", "4"]);
  assert.equal(timeline.remove(2), true);
  timeline.clear();
  assert.equal(container.children.length, 0);
  timeline.destroy();
  assert.equal(container.getAttribute("role"), null);
  assert.throws(() => timeline.append({ id: 5 }), /destroyed/);
});

test("timeline appends do not scan the retained DOM", () => {
  const container = document.createElement("div");
  const timeline = createTimeline(container, { maxMessages: 10, actions: false, autoScroll: false });
  container.querySelectorAll = () => { throw new Error("history scanned"); };
  for (let id = 0; id < 3000; id++) timeline.upsert({ id, body: "message" });
  assert.equal(timeline.size, 10);
  assert.equal(container.children.length, 10);
  timeline.destroy();
});

test("history arriving before an optimistic echo does not leave a duplicate row", () => {
  const container = document.createElement("div");
  const timeline = createTimeline(container, { actions: false });
  timeline.append({ id: "pending", nonce: "n1", body: "draft" });
  timeline.append({ id: "server", body: "saved" });
  timeline.upsert({ id: "server", nonce: "n1", body: "confirmed" });
  assert.equal(timeline.size, 1);
  assert.equal(timeline.get("pending"), null);
  assert.equal(container.children.length, 1);
  timeline.destroy();
});

test("invalid client configuration leaves no partially mounted panel", () => {
  const root = document.createElement("div");
  assert.throws(() => mountChat(root, { url: "ws://chat", topic: "general", maxPending: 0 }), RangeError);
  assert.equal(root.children.length, 0);
});

test("LiveView hooks attach and detach synchronously", () => {
  const hook = { ...WiregridHooks.Composer, el: composerForm(), pushEvent() { throw new Error("destroyed hook used"); } };
  hook.mounted();
  hook.destroyed();
  hook.el.querySelector("textarea").value = "draft";
  hook.el.dispatchEvent(new CustomEvent("submit", { cancelable: true }));
  assert.equal(hook.el.querySelector("textarea").value, "draft");
});

test("mounted chat subscribes, renders once, acknowledges and cleans up", async () => {
  const root = document.createElement("div");
  document.body.append(root);
  const chat = mountChat(root, { url: "ws://chat", topic: "channel:general" });
  const socket = Socket.all.at(-1);
  const textarea = root.querySelector("textarea");
  assert.equal(textarea.disabled, true);
  socket.ready();
  await tick();
  assert.equal(socket.sent.at(-1).op, "subscribe");
  socket.reply();
  await chat.ready;
  assert.equal(textarea.disabled, false);
  const envelope = { type: "event", topic: "general", event_id: "e1", delivery_id: "d1", event: { type: "message", body: "hello" } };
  socket.message(envelope);
  await tick();
  assert.equal(chat.timeline.size, 1);
  assert.equal(socket.sent.at(-1).op, "ack");
  socket.reply();
  await tick();
  socket.message({ ...envelope, delivery_id: "d2" });
  socket.reply();
  await tick();
  assert.equal(chat.timeline.size, 1);
  chat.destroy();
  chat.destroy();
  assert.equal(root.children.length, 0);
  assert.equal(socket.readyState, 3);
});
