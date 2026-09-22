export function createOverlay(panel, options = {}) {
  const root = panel.closest(".wg-modal") || panel;
  let previous = null;
  const focusable = () => [
    ...panel.querySelectorAll(
      'a[href],button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])',
    ),
  ];
  function open() {
    previous = document.activeElement;
    root.hidden = false;
    root.dataset.open = "true";
    (focusable()[0] || panel).focus?.();
  }
  function close() {
    root.hidden = true;
    delete root.dataset.open;
    previous?.focus?.();
    options.onClose?.();
  }
  function keydown(e) {
    if (e.key === "Escape" && options.escape !== false) {
      e.preventDefault();
      close();
      return;
    }
    if (e.key !== "Tab") return;
    const list = focusable();
    if (!list.length) return;
    const first = list[0],
      last = list[list.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
  panel.addEventListener("keydown", keydown);
  return {
    open,
    close,
    destroy() {
      panel.removeEventListener("keydown", keydown);
    },
  };
}

export function bindTabs(root) {
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    for (const item of tabs) {
      const active = item === tab;
      item.setAttribute("aria-selected", active ? "true" : "false");
      item.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(item.getAttribute("aria-controls"));
      if (panel) panel.hidden = !active;
    }
  };
  const click = (e) => {
    const tab = e.target.closest('[role="tab"]');
    if (tab) select(tab);
  };
  const key = (e) => {
    const i = tabs.indexOf(document.activeElement);
    if (i < 0) return;
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
    e.preventDefault();
    const next =
      e.key === "Home"
        ? 0
        : e.key === "End"
          ? tabs.length - 1
          : (i + (e.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
    tabs[next].focus();
    select(tabs[next]);
  };
  root.addEventListener("click", click);
  root.addEventListener("keydown", key);
  return () => {
    root.removeEventListener("click", click);
    root.removeEventListener("keydown", key);
  };
}
