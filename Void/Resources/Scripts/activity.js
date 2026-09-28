// Void — page activity for the tab UI, injected at document start in every frame (isolated world).
//  1. Reading progress (main frame only): how far the page is scrolled, 0…1, throttled.
//  2. Typed text (every frame): the first trusted input into a text field marks the tab as
//     "in use", so it is never put to sleep automatically while the text could be lost.
(() => {
  if (window.__voidActivity) return;
  window.__voidActivity = true;

  const post = (message) => {
    try { window.webkit.messageHandlers.voidActivity.postMessage(message); } catch (_) {}
  };

  if (window === window.top) {
    let last = -1;
    let timer = null;
    const report = () => {
      timer = null;
      const root = document.scrollingElement || document.documentElement;
      if (!root) return;
      const max = root.scrollHeight - window.innerHeight;
      const value = max > 40 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      if (Math.abs(value - last) < 0.004 && !(value === 1 && last !== 1)) return;
      last = value;
      post({ type: 'scroll', value });
    };
    const schedule = () => { if (!timer) timer = setTimeout(report, 100); };
    addEventListener('scroll', schedule, { passive: true });
    addEventListener('resize', schedule, { passive: true });
    addEventListener('load', schedule);
    // Back/forward cache: the page comes back without reloading this script.
    addEventListener('pageshow', () => { last = -1; schedule(); });
  }

  const nonText = /^(checkbox|radio|range|color|file|submit|button|reset|image|hidden)$/i;
  let typed = false;
  addEventListener('input', (event) => {
    if (typed || !event.isTrusted) return;
    const target = event.composedPath ? event.composedPath()[0] : event.target;
    if (!target) return;
    const editable = target.isContentEditable || target.tagName === 'TEXTAREA'
      || (target.tagName === 'INPUT' && !nonText.test(target.type || ''));
    if (!editable) return;
    typed = true;
    post({ type: 'input' });
  }, true);
})();
