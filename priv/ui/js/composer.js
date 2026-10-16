export function bindComposer(form, options = {}) {
  const textarea = form.querySelector("textarea");
  if (!textarea) throw new Error("Wiregrid composer requires a textarea");
  const maxBytes = options.maxBytes ?? 65536;
  const encoder = new TextEncoder();
  let destroyed = false;
  let revision = 0;

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
    const bytes = byteLength();
    if (count) count.textContent = `${bytes}/${maxBytes}`;
    form.dataset.overLimit = bytes > maxBytes ? "true" : "false";
  }
  async function submit() {
    if (destroyed) return false;
    const value = textarea.value;
    if (
      !value.trim() ||
      byteLength() > maxBytes ||
      form.dataset.submitting === "true"
    )
      return;
    form.dataset.submitting = "true";
    const submittedRevision = revision;
    try {
      const result = await options.onSubmit?.(value, { form, textarea });
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
  const onInput = () => { revision++; sync(); };
  const onKey = (e) => {
    const send =
      e.key === "Enter" && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey;
    if (send && options.enterToSend !== false && !e.isComposing) {
      e.preventDefault();
      void submit();
    }
  };
  const onSubmit = (e) => {
    e.preventDefault();
    void submit();
  };
  textarea.addEventListener("input", onInput);
  textarea.addEventListener("keydown", onKey);
  form.addEventListener("submit", onSubmit);
  sync();
  return {
    submit,
    destroy() {
      destroyed = true;
      delete form.dataset.submitting;
      textarea.removeEventListener("input", onInput);
      textarea.removeEventListener("keydown", onKey);
      form.removeEventListener("submit", onSubmit);
    },
  };
}
