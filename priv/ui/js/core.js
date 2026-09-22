export const version = "1.0.0";

export function qs(root, selector) {
  return (root || document).querySelector(selector);
}
export function qsa(root, selector) {
  return [...(root || document).querySelectorAll(selector)];
}

export function createStore(initial = {}) {
  let state = structuredCloneSafe(initial);
  const listeners = new Set();
  return {
    get: () => state,
    set(next) {
      state = typeof next === "function" ? next(state) : next;
      for (const fn of listeners) fn(state);
      return state;
    },
    patch(partial) {
      return this.set({ ...state, ...partial });
    },
    subscribe(fn) {
      listeners.add(fn);
      fn(state);
      return () => listeners.delete(fn);
    },
  };
}

function structuredCloneSafe(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return value && typeof value === "object"
    ? JSON.parse(JSON.stringify(value))
    : value;
}

export function setTheme(theme, root = document.documentElement) {
  if (!root) return;
  root.dataset.wgTheme = theme;
  try {
    localStorage.setItem("wiregrid.theme", theme);
  } catch (_) {}
}

export function restoreTheme(
  root = document.documentElement,
  fallback = "dark",
) {
  let theme = fallback;
  try {
    theme = localStorage.getItem("wiregrid.theme") || fallback;
  } catch (_) {}
  setTheme(theme, root);
  return theme;
}

export function setDensity(density, root = document.documentElement) {
  if (!root) return;
  root.dataset.wgDensity = density;
}

export function text(tag, value, className) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  el.textContent = value == null ? "" : String(value);
  return el;
}

export function uid(prefix = "wg") {
  if (globalThis.crypto?.randomUUID) return `${prefix}-${crypto.randomUUID()}`;
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

export function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}
