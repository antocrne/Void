// Chrome Web Store: its install button only works in Chrome ("Add to Chrome", disabled here).
// Void puts its own in its place — a copy with the same look — which asks Void to install
// (or remove) the extension of the page. Runs in Void's isolated world, main frame only.
(() => {
  if (location.hostname !== "chromewebstore.google.com") return;

  const labels = { add: "Ajouter à Void", adding: "Ajout en cours…", remove: "Retirer de Void" };
  let state = "add";
  let askedFor = null;

  const extensionID = () => (location.pathname.match(/\/detail\/(?:[^/]+\/)?([a-p]{32})(?:[/?#]|$)/) || [])[1];
  const post = (action) => webkit.messageHandlers.voidStore.postMessage({ action, id: extensionID() });

  // The store's own button: disabled, and it names Chrome (in every language).
  const storeButton = () => [...document.querySelectorAll("button:not([data-void-store])")]
    .find((b) => /chrome/i.test(b.innerText || "") && (b.disabled || b.getAttribute("aria-disabled") === "true"));

  function setLabel(button) {
    const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
    let first = true;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.nodeValue.trim()) continue;
      node.nodeValue = first ? labels[state] : "";
      first = false;
    }
    button.disabled = state === "adding";
    button.style.opacity = state === "adding" ? "0.6" : "";
  }

  function apply() {
    const id = extensionID();
    let ours = document.querySelector("button[data-void-store]");
    if (!id) { if (ours) ours.remove(); return; }
    if (askedFor !== id) { askedFor = id; state = "add"; post("state"); }
    const theirs = storeButton();
    if (theirs && !(ours && ours.previousElementSibling === theirs)) {
      if (ours) ours.remove();
      ours = theirs.cloneNode(true);
      ours.dataset.voidStore = "1";
      ours.removeAttribute("aria-disabled");
      // The store's own click handling (jsaction) stays with its button.
      for (const element of [ours, ...ours.querySelectorAll("[jsaction]")]) element.removeAttribute("jsaction");
      ours.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        // The user's click only: not one the page's scripts make.
        if (event.isTrusted && state !== "adding") post(state === "remove" ? "remove" : "add");
      }, true);
      theirs.style.display = "none";
      theirs.after(ours);
    }
    if (ours && ours.dataset.voidState !== state) {
      ours.dataset.voidState = state;
      setLabel(ours);
    }
  }

  // Called by Void: "add", "adding" or "remove".
  window.__voidStore = { set(value) { state = value; apply(); } };

  let pending = false;
  new MutationObserver(() => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => { pending = false; apply(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  apply();
})();
