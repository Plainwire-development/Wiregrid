export function connectChat(url, handlers = {}) {
  const positive = (name, fallback) => {
    const value = handlers[name] ?? fallback;
    if (!Number.isSafeInteger(value) || value < 1 || value > 2147483647)
      throw new RangeError(`Wiregrid ${name} must be a positive integer`);
    return value;
  };
  const maxPending = positive("maxPending", 256);
  const requestTimeout = positive("requestTimeoutMs", 10000);
  const connectTimeout = positive("connectTimeoutMs", 10000);
  const maxBufferedBytes = positive("maxBufferedBytes", 1048576);
  const socket = new WebSocket(url);
  socket.binaryType = "arraybuffer";
  const pending = new Map();
  let queuedBytes = 0;
  const encoder = new TextEncoder();
  let seq = 0;
  let closed = false;
  let initialized = false;
  let resolveReady, rejectReady;
  const ready = new Promise((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  // Handler-only consumers do not have to observe ready separately.
  ready.catch(() => {});

  function report(error) {
    try {
      Promise.resolve(handlers.onError?.(error)).catch(() => {});
    } catch (_) {}
  }
  function notify(name, value) {
    try {
      Promise.resolve(handlers[name]?.(value)).catch(report);
    } catch (error) {
      report(error);
    }
  }
  function debug(event, op) {
    if (handlers.onDebug) notify("onDebug", { event, op, pending: pending.size });
  }
  function settle(id, error, value) {
    const item = pending.get(id);
    if (!item) return;
    pending.delete(id);
    if (!item.sent) queuedBytes -= item.payloadBytes;
    clearTimeout(item.timer);
    if (error) item.reject(error);
    else item.resolve(value);
  }
  function finish(error) {
    if (closed) return;
    closed = true;
    clearTimeout(connectTimer);
    rejectReady(error);
    for (const id of pending.keys()) settle(id, error);
    debug("closed");
  }
  function fail(error) {
    if (closed) return;
    finish(error);
    report(error);
    socket.close();
  }
  const connectTimer = setTimeout(
    () => fail(new Error("wiregrid connection timed out")),
    connectTimeout,
  );

  socket.addEventListener("open", () => debug("open"));
  socket.addEventListener("error", () => fail(new Error("wiregrid socket failed")));
  socket.addEventListener("close", (event) => {
    finish(new Error("wiregrid socket closed"));
    notify("onClose", event);
  });
  socket.addEventListener("message", (event) => {
    if (closed) return;
    let message;
    try {
      message = JSON.parse(
        typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data),
      );
      if (!message || typeof message !== "object" || Array.isArray(message))
        throw new Error("wiregrid invalid server message");
    } catch (error) {
      report(error);
      return;
    }
    if (message.type === "ready" && !initialized) {
      initialized = true;
      clearTimeout(connectTimer);
      resolveReady(message);
      for (const id of pending.keys()) sendPending(id);
      debug("ready");
      notify("onReady", message);
    } else if (message.type === "event") notify("onEvent", message);
    else if (!initialized && message.type === "error") {
      fail(new Error("wiregrid handshake rejected"));
    } else if (["response", "error"].includes(message.type) && message.id != null && pending.has(message.id)) {
      const error = message.type === "error" || message.ok === false;
      settle(message.id, error ? message : null, message);
      debug(error ? "rejected" : "response");
    }
  });

  function sendPending(id) {
    const item = pending.get(id);
    if (!item || item.sent) return;
    try {
      if (closed || socket.readyState !== WebSocket.OPEN)
        throw new Error("wiregrid socket closed");
      if (socket.bufferedAmount + item.payloadBytes > maxBufferedBytes)
        throw new Error("wiregrid socket backpressure");
      const payload = item.payload;
      queuedBytes -= item.payloadBytes;
      item.sent = true;
      delete item.payload;
      delete item.payloadBytes;
      socket.send(payload);
      debug("request", item.op);
    } catch (error) { settle(id, error); }
  }

  function call(op, fields = {}) {
    if (closed) return Promise.reject(new Error("wiregrid socket closed"));
    if (pending.size >= maxPending)
      return Promise.reject(new Error("wiregrid too many pending requests"));
    do { seq = seq >= 4294967295 ? 1 : seq + 1; } while (pending.has(seq));
    const id = seq;
    let payload, payloadBytes;
    try {
      payload = JSON.stringify({ ...fields, id, op });
      payloadBytes = encoder.encode(payload).byteLength;
      if (payloadBytes > maxBufferedBytes) throw new Error("wiregrid request too large");
      if (queuedBytes + socket.bufferedAmount + payloadBytes > maxBufferedBytes)
        throw new Error("wiregrid socket backpressure");
    } catch (error) {
      return Promise.reject(error);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        settle(id, new Error("wiregrid request timed out"));
        debug("timeout", op);
      }, requestTimeout);
      pending.set(id, { resolve, reject, timer, op, payload, payloadBytes, sent: false });
      queuedBytes += payloadBytes;
      if (initialized) sendPending(id);
    });
  }

  return {
    ready,
    get pendingRequests() { return pending.size; },
    subscribe: (topic) => call("subscribe", { topic }),
    unsubscribe: (topic) => call("unsubscribe", { topic }),
    say(topic, body, extra = {}) {
      return call("publish", {
        topic, event: { ...extra, type: "message", body }, class: "durable", persist: true,
      });
    },
    publish: (topic, event, options = {}) => call("publish", { ...options, topic, event }),
    history: (topic, cursor = null, limit = 50) => call("history", { topic, cursor, limit }),
    ack: (deliveryId) => call("ack", { delivery_id: deliveryId }),
    presence: (status) => call("presence", { status }),
    joinRoom: (room) => call("join_room", { room }),
    leaveRoom: (room) => call("leave_room", { room }),
    ping: (nonce = Date.now()) => call("ping", { nonce }),
    close() {
      finish(new Error("wiregrid socket closed"));
      socket.close();
    },
  };
}
