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
    let destroyed = false;
    let revision = 0;
    function bytes() {
      return encoder.encode(textarea.value).byteLength;
    }
    function sync() {
      textarea.style.height = "auto";
      textarea.style.height =
        Math.min(textarea.scrollHeight, options.maxHeight || 220) + "px";
      const count = form.querySelector("[data-wg-byte-count]");
      if (count) count.textContent = bytes() + "/" + maxBytes;
      form.dataset.overLimit = bytes() > maxBytes ? "true" : "false";
    }
    async function submit() {
      if (destroyed) return false;
      const value = textarea.value;
      if (!value.trim() || bytes() > maxBytes || form.dataset.submitting === "true") return false;
      form.dataset.submitting = "true";
      const submittedRevision = revision;
      try {
        const result = options.onSubmit && await options.onSubmit(value, { form, textarea });
        if (!destroyed && result !== false && textarea.value === value && revision === submittedRevision) {
          textarea.value = "";
          sync();
        }
        return result !== false;
      } catch (error) {
        if (!destroyed) {
          try {
            if (options.onError) await options.onError(error, { form, textarea });
            else form.dispatchEvent(new CustomEvent("wiregrid:error", { detail: error, bubbles: true }));
          } catch (handlerError) {
            form.dispatchEvent(new CustomEvent("wiregrid:error", { detail: handlerError, bubbles: true }));
          }
        }
        return false;
      } finally {
        if (!destroyed) delete form.dataset.submitting;
      }
    }
    function onInput() { revision++; sync(); }
    function onKey(event) {
      if (
        event.key === "Enter" &&
        !event.shiftKey &&
        !event.altKey && !event.ctrlKey && !event.metaKey &&
        !event.isComposing &&
        options.enterToSend !== false
      ) {
        event.preventDefault();
        void submit();
      }
    }
    function onSubmit(event) {
      event.preventDefault();
      void submit();
    }
    textarea.addEventListener("input", onInput);
    textarea.addEventListener("keydown", onKey);
    form.addEventListener("submit", onSubmit);
    sync();
    return {
      submit: submit,
      destroy: function () {
        destroyed = true;
        delete form.dataset.submitting;
        textarea.removeEventListener("input", onInput);
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
