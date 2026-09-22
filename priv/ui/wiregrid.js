(function (global) {
  "use strict";

  const WG = (global.WiregridUI = global.WiregridUI || {});
  WG.version = "1.0.0";

  function rootOf(root) {
    return root || document.documentElement;
  }

  WG.setTheme = function (theme, root) {
    rootOf(root).dataset.wgTheme = theme;
  };
  WG.setDensity = function (density, root) {
    rootOf(root).dataset.wgDensity = density;
  };

  WG.mountComposer = function (form, options) {
    options = options || {};
    const textarea = form.querySelector("textarea");
    if (!textarea) throw new Error("Wiregrid composer requires a textarea");
    const maxBytes = options.maxBytes || 65536;
    const encoder = new TextEncoder();
    function bytes() {
      return encoder.encode(textarea.value).byteLength;
    }
    function sync() {
      textarea.style.height = "auto";
      textarea.style.height =
        Math.min(textarea.scrollHeight, options.maxHeight || 220) + "px";
      const count = form.querySelector("[data-wg-byte-count]");
      if (count) count.textContent = bytes() + "/" + maxBytes;
    }
    function submit() {
      const value = textarea.value;
      if (!value.trim() || bytes() > maxBytes) return;
      const result = options.onSubmit && options.onSubmit(value);
      if (result !== false) {
        textarea.value = "";
        sync();
      }
    }
    function onKey(event) {
      if (
        event.key === "Enter" &&
        !event.shiftKey &&
        !event.isComposing &&
        options.enterToSend !== false
      ) {
        event.preventDefault();
        submit();
      }
    }
    function onSubmit(event) {
      event.preventDefault();
      submit();
    }
    textarea.addEventListener("input", sync);
    textarea.addEventListener("keydown", onKey);
    form.addEventListener("submit", onSubmit);
    sync();
    return {
      submit: submit,
      destroy: function () {
        textarea.removeEventListener("input", sync);
        textarea.removeEventListener("keydown", onKey);
        form.removeEventListener("submit", onSubmit);
      },
    };
  };

  WG.appendMessage = function (container, message) {
    const article = document.createElement("article");
    article.className = "wg-message";
    article.dataset.messageId = String(message.id || "");
    const content = document.createElement("div");
    content.className = "wg-message__content";
    const author = document.createElement("span");
    author.className = "wg-author";
    author.textContent = message.author || "";
    const body = document.createElement("div");
    body.className = "wg-message-body";
    body.textContent = message.body || "";
    content.append(author, body);
    article.append(content);
    container.append(article);
    return article;
  };

  WG.jumpToMessage = function (root, id) {
    const node = root.querySelector(
      '[data-message-id="' + CSS.escape(String(id)) + '"]',
    );
    if (!node) return false;
    node.scrollIntoView({
      behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "auto"
        : "smooth",
      block: "center",
    });
    node.dataset.highlighted = "true";
    setTimeout(function () {
      delete node.dataset.highlighted;
    }, 1400);
    return true;
  };
})(globalThis);
