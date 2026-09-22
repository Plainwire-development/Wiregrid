export function bindComposer(form, options = {}) {
  const textarea = form.querySelector("textarea");
  if (!textarea) throw new Error("Wiregrid composer requires a textarea");
  const maxBytes = options.maxBytes ?? 65536;
  const encoder = new TextEncoder();

  function resize() {
    textarea.style.height = "auto";
    textarea.style.height = `${Math.min(textarea.scrollHeight, options.maxHeight ?? 220)}px`;
  }
  function byteLength() {
    return encoder.encode(textarea.value).byteLength;
  }
  function sync() {
    resize();
    const count = form.querySelector("[data-wg-byte-count]");
    if (count) count.textContent = `${byteLength()}/${maxBytes}`;
    form.dataset.overLimit = byteLength() > maxBytes ? "true" : "false";
  }
  async function submit() {
    const value = textarea.value;
    if (
      !value.trim() ||
      byteLength() > maxBytes ||
      form.dataset.submitting === "true"
    )
      return;
    form.dataset.submitting = "true";
    try {
      const result = await options.onSubmit?.(value, { form, textarea });
      if (result !== false) {
        textarea.value = "";
        sync();
      }
    } finally {
      delete form.dataset.submitting;
    }
  }
  const onInput = () => sync();
  const onKey = (e) => {
    const send =
      e.key === "Enter" && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey;
    if (send && options.enterToSend !== false && !e.isComposing) {
      e.preventDefault();
      submit();
    }
  };
  const onSubmit = (e) => {
    e.preventDefault();
    submit();
  };
  textarea.addEventListener("input", onInput);
  textarea.addEventListener("keydown", onKey);
  form.addEventListener("submit", onSubmit);
  sync();
  return {
    submit,
    destroy() {
      textarea.removeEventListener("input", onInput);
      textarea.removeEventListener("keydown", onKey);
      form.removeEventListener("submit", onSubmit);
    },
  };
}
