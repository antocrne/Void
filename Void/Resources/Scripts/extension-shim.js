// Chrome extensions in WebKit: what they need that Chrome gives and WebKit doesn't. Void loads
// this file first in each of an extension's contexts — background script, extension pages,
// content scripts (ExtensionManager.addShims).
(() => {
  const done = Symbol.for("void.extension-shim");
  if (globalThis[done]) return;
  globalThis[done] = true;

  const native = globalThis.browser || globalThis.chrome;
  if (!native || !native.runtime) return;

  // requestIdleCallback: in Chrome and Firefox, not in WebKit. Proton Pass detects login forms
  // from it: without it, no icon or dropdown in the fields.
  if (typeof globalThis.requestIdleCallback !== "function") {
    globalThis.requestIdleCallback = (callback) => {
      const start = Date.now();
      return setTimeout(() => callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) }), 1);
    };
    globalThis.cancelIdleCallback = (id) => clearTimeout(id);
  }

  // WebKit finds the context to send an event to (a message, a port, onStartup…) through its
  // `browser` / `chrome` globals. Some extensions replace them once started, to hide the API from
  // other scripts (Proton Pass puts a Proxy that answers nothing in their place): in Chrome that
  // changes nothing, in WebKit the extension then never hears anything again. So they stay
  // WebKit's objects; a replacement is ignored (the extension keeps its own references).
  // It also holds the objects: WebKit's wrappers that nobody holds can be collected and rebuilt,
  // losing what is added to them below.
  for (const name of ["browser", "chrome"]) {
    const value = globalThis[name];
    if (!value) continue;
    try {
      Object.defineProperty(globalThis, name, { get: () => value, set: () => {}, configurable: true, enumerable: true });
    } catch {}
  }
  const runtime = native.runtime;
  try {
    Object.defineProperty(native, "runtime", { value: runtime, configurable: true, writable: true, enumerable: true });
  } catch {}

  // Content scripts run in web pages: the rest is for the extension's own contexts.
  if (globalThis.location && globalThis.location.protocol !== "webkit-extension:") return;

  // Chrome APIs WebKit doesn't have, which extensions touch as soon as their background script
  // starts: one missing (chrome.runtime.onUpdateAvailable.addListener…) and the whole script
  // stops. Inert stand-ins, only where WebKit has nothing.
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (listener) => { listeners.add(listener); },
      removeListener: (listener) => { listeners.delete(listener); },
      hasListener: (listener) => listeners.has(listener),
      hasListeners: () => listeners.size > 0,
    };
  };
  const unsupported = (name) => () => Promise.reject(new Error(`${name} n'est pas pris en charge par Void`));
  const define = (target, name, make) => {
    if (!target || target[name] !== undefined) return;
    try {
      Object.defineProperty(target, name, { value: make(), configurable: true, writable: true, enumerable: true });
    } catch {}
  };

  for (const name of ["onUpdateAvailable", "onRestartRequired", "onBrowserUpdateAvailable", "onSuspend",
                      "onSuspendCanceled", "onMessageExternal", "onConnectExternal"]) {
    define(runtime, name, event);
  }
  define(runtime, "requestUpdateCheck", () => () => Promise.resolve({ status: "no_update" }));
  // tabs.getCurrent(): in Chrome, the tab showing this very page, and nothing in a popup. WebKit
  // gives a popup the tab it was opened over; extensions then take their popup for a page in a
  // tab (Proton Pass sizes it to 100% of the window, and WebKit, which sizes the popup to its
  // content, shrinks it to nothing).
  const tabs = native.tabs;
  if (tabs && typeof tabs.getCurrent === "function") {
    try {
      Object.defineProperty(native, "tabs", { value: tabs, configurable: true, writable: true, enumerable: true });
    } catch {}
    const getCurrent = tabs.getCurrent.bind(tabs);
    const page = (url) => String(url || "").split("#")[0];
    const current = () => getCurrent().then((tab) => (tab && page(tab.url) === page(location.href) ? tab : undefined));
    try {
      Object.defineProperty(tabs, "getCurrent", {
        value: (callback) => {
          if (typeof callback !== "function") return current();
          current().then(callback, () => callback(undefined));
        },
        configurable: true, writable: true, enumerable: true,
      });
    } catch {}
  }
  // Offscreen documents (clipboard, audio…): refused, the way Chrome refuses a bad request, so
  // that extensions fall back on something else instead of stopping.
  define(native, "offscreen", () => ({
    Reason: {},
    createDocument: unsupported("chrome.offscreen"),
    hasDocument: () => Promise.resolve(false),
    closeDocument: () => Promise.resolve(),
  }));
  // Side panel: its settings are accepted, opening it isn't possible.
  define(native, "sidePanel", () => ({
    setPanelBehavior: () => Promise.resolve(),
    getPanelBehavior: () => Promise.resolve({ openPanelOnActionClick: false }),
    setOptions: () => Promise.resolve(),
    getOptions: () => Promise.resolve({ enabled: false }),
    open: unsupported("chrome.sidePanel"),
  }));
})();
