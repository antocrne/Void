// Void — core helpers, injected at document start in every frame (isolated world).
(() => {
  if (window.__voidCore) return;
  window.__voidCore = true;

  // 1. Remember the link / image under a right-click so the native context menu can offer
  //    "Open in background tab" and "Open in private tab". The message is sent while the
  //    event is dispatched, i.e. before WebKit asks the app to show the menu.
  document.addEventListener('contextmenu', (event) => {
    let link = null;
    let image = null;
    for (const el of event.composedPath ? event.composedPath() : []) {
      if (!link && el.tagName === 'A' && el.href) link = el;
      if (!image && el.tagName === 'IMG') image = el;
    }
    try {
      window.webkit.messageHandlers.voidContext.postMessage({
        href: link ? String(link.href) : '',
        image: image ? (image.currentSrc || image.src || '') : ''
      });
    } catch (_) {}
  }, true);

  // 2. Embedded players (YouTube, Vimeo… in iframes) often lack allow="picture-in-picture".
  //    Add it (and fullscreen) as soon as an iframe is inserted, before its document is created.
  const patch = (frame) => {
    const allow = frame.getAttribute('allow') || '';
    if (!/picture-in-picture/.test(allow)) {
      frame.setAttribute('allow', (allow ? allow.replace(/;?\s*$/, '; ') : '') + 'picture-in-picture; fullscreen');
    }
    if (!frame.hasAttribute('allowfullscreen')) frame.setAttribute('allowfullscreen', '');
  };
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType !== 1) continue;
        if (node.tagName === 'IFRAME') patch(node);
        else if (node.firstElementChild) node.querySelectorAll('iframe').forEach(patch);
      }
    }
  });
  observer.observe(document, { childList: true, subtree: true });
})();
