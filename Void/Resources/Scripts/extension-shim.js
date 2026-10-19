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

  // Void asks the background whether it is there (ExtensionManager.backgroundAnswers): what
  // WebKit tells of a service worker isn't reliable. Registered before the extension's own
  // listeners: its answer comes first, whatever they make of the message.
  if (typeof ServiceWorkerGlobalScope === "function" && globalThis instanceof ServiceWorkerGlobalScope) {
    try {
      runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || message.voidPing !== true || !sender || sender.id !== runtime.id) return;
        sendResponse({ voidPong: true });
      });
    } catch {}
  }

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
  // An answer for the promise and the callback styles of Chrome's APIs.
  const settle = (promise, callback) => {
    if (typeof callback !== "function") return promise;
    promise.then((value) => callback(value), () => callback());
  };
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
  // Tab groups: Void has none. Their constants are read as soon as some extensions start (Claude
  // lists the group colors at load); every tab is outside any group, grouping is refused.
  if (native.tabs) {
    define(native, "tabGroups", () => ({
      TAB_GROUP_ID_NONE: -1,
      Color: Object.fromEntries(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        .map((color) => [color.toUpperCase(), color])),
      onCreated: event(), onUpdated: event(), onRemoved: event(), onMoved: event(),
      query: (info, callback) => settle(Promise.resolve([]), callback),
      get: unsupported("chrome.tabGroups"),
      update: unsupported("chrome.tabGroups"),
      move: unsupported("chrome.tabGroups"),
    }));
    define(native.tabs, "group", () => unsupported("chrome.tabs.group"));
    define(native.tabs, "ungroup", () => unsupported("chrome.tabs.ungroup"));
    define(native.tabs, "TAB_ID_NONE", () => -1);
  }
  // The debugger (Chrome DevTools Protocol): WebKit has none. Its events are listened to at
  // start; attaching is refused, so what drives pages through it says it can't.
  define(native, "debugger", () => ({
    onEvent: event(), onDetach: event(),
    attach: unsupported("chrome.debugger"),
    detach: () => Promise.resolve(),
    sendCommand: unsupported("chrome.debugger"),
    getTargets: (callback) => settle(Promise.resolve([]), callback),
  }));
  // System notifications: not shown (WebKit has no API for them), accepted silently.
  define(native, "notifications", () => ({
    onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event(),
    create: (...args) => settle(Promise.resolve(typeof args[0] === "string" ? args[0] : ""), args.find((a) => typeof a === "function")),
    update: (id, options, callback) => settle(Promise.resolve(false), callback),
    clear: (id, callback) => settle(Promise.resolve(false), callback),
    getAll: (callback) => settle(Promise.resolve({}), callback),
  }));
  // declarativeNetRequest: WebKit has the rules, not Chrome's named constants for them.
  const constants = (values) => Object.fromEntries(values.map((value) => [value.replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), value]));
  const rules = native.declarativeNetRequest;
  if (rules) {
    define(rules, "RuleActionType", () => constants(["block", "redirect", "allow", "upgradeScheme", "modifyHeaders", "allowAllRequests"]));
    define(rules, "HeaderOperation", () => constants(["append", "set", "remove"]));
    define(rules, "ResourceType", () => constants(["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
      "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]));
    define(rules, "DomainType", () => constants(["firstParty", "thirdParty"]));
    define(rules, "RequestMethod", () => constants(["connect", "delete", "get", "head", "options", "patch", "post", "put", "other"]));
  }
  // runtime.getContexts (which pages of the extension are open): none known.
  define(runtime, "ContextType", () => ({ TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL" }));
  define(runtime, "getContexts", () => (filter, callback) => settle(Promise.resolve([]), callback));
  // Offscreen documents (clipboard, audio…): refused, the way Chrome refuses a bad request, so
  // that extensions fall back on something else instead of stopping.
  define(native, "offscreen", () => ({
    Reason: {},
    createDocument: unsupported("chrome.offscreen"),
    hasDocument: () => Promise.resolve(false),
    closeDocument: () => Promise.resolve(),
  }));
  // Side panel (Claude, Perplexity…): Void shows the extension's panel page on the right of the
  // page. It is asked for as a tab carrying the `void-side-panel` parameter, which Void takes
  // out of the address and puts in its panel (ExtensionManager, openNewTabUsing). The settings
  // live in the context that sets them, usually the background, which also opens the panel.
  const panel = {
    path: ((runtime.getManifest() || {}).side_panel || {}).default_path || "",
    paths: new Map(),
    disabled: new Set(),
    onAction: false,
  };
  const openPanel = (options) => {
    const tabId = options && options.tabId;
    const path = (tabId != null && panel.paths.get(tabId)) || panel.path;
    if (!path || (tabId != null && panel.disabled.has(tabId))) {
      return Promise.reject(new Error("Aucun panneau latéral pour cet onglet"));
    }
    const url = new URL(runtime.getURL(path.replace(/^\//, "")));
    url.searchParams.set("void-side-panel", "1");
    const create = { url: url.href, active: true };
    if (tabId != null) create.openerTabId = tabId;
    if (options && options.windowId != null) create.windowId = options.windowId;
    // Void answers with no tab: the panel isn't one.
    return native.tabs.create(create).then(() => undefined, () => undefined);
  };
  const ownPanel = native.sidePanel === undefined;
  define(native, "sidePanel", () => ({
    setPanelBehavior: (behavior, callback) => {
      if (behavior && "openPanelOnActionClick" in behavior) panel.onAction = !!behavior.openPanelOnActionClick;
      return settle(Promise.resolve(), callback);
    },
    getPanelBehavior: (callback) => settle(Promise.resolve({ openPanelOnActionClick: panel.onAction }), callback),
    setOptions: (options, callback) => {
      const { tabId, path, enabled } = options || {};
      if (tabId != null) {
        if (path) panel.paths.set(tabId, path);
        if (enabled === false) panel.disabled.add(tabId); else if (enabled === true) panel.disabled.delete(tabId);
      } else if (path) {
        panel.path = path;
      }
      return settle(Promise.resolve(), callback);
    },
    getOptions: (options, callback) => {
      const tabId = options && options.tabId;
      const path = (tabId != null && panel.paths.get(tabId)) || panel.path;
      return settle(Promise.resolve({ path, enabled: !!path && !(tabId != null && panel.disabled.has(tabId)) }), callback);
    },
    open: (options, callback) => settle(openPanel(options), callback),
  }));
  // setPanelBehavior({ openPanelOnActionClick: true }): the button opens the panel. Heard in the
  // background only (a service worker, or an older extension's background page).
  const action = native.action || native.browserAction;
  const inBackground = (typeof ServiceWorkerGlobalScope === "function" && globalThis instanceof ServiceWorkerGlobalScope)
    || (() => { try { return native.extension.getBackgroundPage() === globalThis; } catch { return false; } })();
  if (ownPanel && inBackground && action && action.onClicked) {
    try {
      action.onClicked.addListener((tab) => {
        if (panel.onAction) openPanel({ tabId: tab && tab.id, windowId: tab && tab.windowId }).catch(() => {});
      });
    } catch {}
  }
})();
