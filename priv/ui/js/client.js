export function connectChat(url, handlers = {}) {
  const socket = new WebSocket(url);
  const pending = new Map();
  let seq = 0;
  let settleOpen;
  const untilOpen = new Promise((resolve, reject) => {
    settleOpen = { resolve, reject };
  });

  socket.addEventListener("open", () => settleOpen.resolve());
  socket.addEventListener("error", () =>
    settleOpen.reject(new Error("wiregrid socket failed")),
  );
  socket.addEventListener("close", () => {
    settleOpen.reject(new Error("wiregrid socket closed"));
    for (const item of pending.values())
      item.reject(new Error("wiregrid socket closed"));
    pending.clear();
    handlers.onClose?.();
  });

  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(
        typeof event.data === "string"
          ? event.data
          : new TextDecoder().decode(event.data),
      );
    } catch {
      return;
    }
    if (message.type === "ready") handlers.onReady?.(message);
    else if (message.type === "event") handlers.onEvent?.(message);
    else if (message.id != null && pending.has(message.id)) {
      const item = pending.get(message.id);
      pending.delete(message.id);
      if (message.type === "error" || message.ok === false)
        item.reject(message);
      else item.resolve(message);
    }
  });

  function call(op, fields = {}) {
    const id = ++seq;
    return untilOpen.then(
      () =>
        new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          socket.send(JSON.stringify({ id, op, ...fields }));
        }),
    );
  }

  return {
    ready: untilOpen,
    subscribe(topic) {
      return call("subscribe", { topic });
    },
    say(topic, body, extra = {}) {
      return call("publish", {
        topic,
        event: { type: "message", body, ...extra },
        class: "durable",
        persist: true,
      });
    },
    publish(topic, event, options = {}) {
      return call("publish", { topic, event, ...options });
    },
    history(topic, cursor = null, limit = 50) {
      return call("history", { topic, cursor, limit });
    },
    ack(deliveryId) {
      return call("ack", { delivery_id: deliveryId });
    },
    presence(status) {
      return call("presence", { status });
    },
    close() {
      socket.close();
    },
  };
}
