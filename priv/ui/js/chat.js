import { qsa, text, uid, clamp } from "./core.js";

export function renderMessage(message, options = {}) {
  const article = document.createElement("article");
  article.className = `wg-message${message.compact ? " wg-message--compact" : ""}`;
  article.dataset.messageId = String(message.id ?? uid("message"));
  article.tabIndex = -1;

  const avatar = document.createElement(message.avatarUrl ? "img" : "div");
  avatar.className = "wg-avatar";
  if (message.avatarUrl) {
    avatar.src = message.avatarUrl;
    avatar.alt = "";
    avatar.loading = "lazy";
  }

  const content = document.createElement("div");
  content.className = "wg-message__content";
  const head = document.createElement("div");
  head.className = "wg-message-head";
  head.append(text("span", message.author ?? "Unknown", "wg-author"));
  if (message.time) head.append(text("time", message.time, "wg-time"));
  content.append(head);

  if (message.reply) content.append(renderReply(message.reply));
  const body = text("div", message.body ?? "", "wg-message-body");
  content.append(body);

  if (Array.isArray(message.reactions) && message.reactions.length) {
    const reactions = document.createElement("div");
    reactions.className = "wg-reactions";
    for (const reaction of message.reactions)
      reactions.append(renderReaction(reaction));
    content.append(reactions);
  }

  article.append(avatar, content);
  if (options.actions !== false) article.append(renderActions(options.actions));
  return article;
}

function renderReply(reply) {
  const el = text(
    "button",
    `${reply.author ? `${reply.author}: ` : ""}${reply.body ?? ""}`,
    "wg-reply-preview",
  );
  el.type = "button";
  if (reply.id != null) el.dataset.wgJumpMessage = String(reply.id);
  return el;
}

function renderReaction(reaction) {
  const btn = text(
    "button",
    `${reaction.emoji ?? ""} ${reaction.count ?? 0}`,
    "wg-reaction",
  );
  btn.type = "button";
  btn.dataset.wgReaction = String(reaction.emoji ?? "");
  btn.setAttribute("aria-pressed", reaction.mine ? "true" : "false");
  return btn;
}

function renderActions(actions = ["react", "reply", "more"]) {
  const bar = document.createElement("div");
  bar.className = "wg-message-actions";
  for (const action of actions) {
    const b = text(
      "button",
      action,
      "wg-button wg-button--ghost wg-button--sm",
    );
    b.type = "button";
    b.dataset.wgMessageAction = action;
    bar.append(b);
  }
  return bar;
}

export function appendMessage(container, message, options = {}) {
  const node = renderMessage(message, options);
  container.append(node);
  trimTimeline(container, options.maxMessages ?? 2000);
  return node;
}

export function upsertMessage(container, message, options = {}) {
  const id = CSS.escape(String(message.id));
  const old = container.querySelector(`[data-message-id="${id}"]`);
  const node = renderMessage(message, options);
  if (old) old.replaceWith(node);
  else container.append(node);
  trimTimeline(container, options.maxMessages ?? 2000);
  return node;
}

export function reconcileOptimistic(container, nonce, message, options = {}) {
  const selector = `[data-wg-nonce="${CSS.escape(String(nonce))}"]`;
  const old = container.querySelector(selector);
  const node = renderMessage(message, options);
  if (old) old.replaceWith(node);
  else container.append(node);
  return node;
}

export function trimTimeline(container, maxMessages = 2000) {
  const max = clamp(Number(maxMessages) || 2000, 100, 20000);
  const nodes = qsa(container, ".wg-message");
  for (let i = 0; i < nodes.length - max; i++) nodes[i].remove();
}

export function jumpToMessage(root, messageId, duration = 1400) {
  const node = root.querySelector(
    `[data-message-id="${CSS.escape(String(messageId))}"]`,
  );
  if (!node) return false;
  node.scrollIntoView({
    behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
      ? "auto"
      : "smooth",
    block: "center",
  });
  node.dataset.highlighted = "true";
  node.focus({ preventScroll: true });
  setTimeout(() => delete node.dataset.highlighted, duration);
  return true;
}

export function bindChatActions(root, handlers = {}) {
  const onClick = (event) => {
    const jump = event.target.closest("[data-wg-jump-message]");
    if (jump) {
      jumpToMessage(root, jump.dataset.wgJumpMessage);
      return;
    }
    const reaction = event.target.closest("[data-wg-reaction]");
    if (reaction && handlers.reaction)
      handlers.reaction(
        reaction.dataset.wgReaction,
        reaction.closest(".wg-message"),
        event,
      );
    const action = event.target.closest("[data-wg-message-action]");
    if (action && handlers.action)
      handlers.action(
        action.dataset.wgMessageAction,
        action.closest(".wg-message"),
        event,
      );
  };
  root.addEventListener("click", onClick);
  return () => root.removeEventListener("click", onClick);
}
