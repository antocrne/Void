// Void — element picker for "Hide element" (⌘⇧H). Evaluated on demand in the main frame.
// Hover highlights, click hides and reports a CSS selector, Escape cancels.
(() => {
  if (window.__voidHiderActive) return 'active';
  window.__voidHiderActive = true;

  const post = (msg) => { try { window.webkit.messageHandlers.voidHider.postMessage(msg); } catch (_) {} };
  // Accent color chosen in Void's settings (passed as an argument by ElementHider).
  const accent = typeof voidAccent === 'string' ? voidAccent : '#9D8FFF';

  const box = document.createElement('div');
  Object.assign(box.style, {
    position: 'fixed', pointerEvents: 'none', zIndex: '2147483647', display: 'none',
    border: '2px solid ' + accent, background: accent + '29', borderRadius: '4px',
    transition: 'all 70ms ease-out', boxSizing: 'border-box'
  });
  const tip = document.createElement('div');
  tip.textContent = 'Cliquez sur un élément pour le masquer — Échap pour annuler';
  Object.assign(tip.style, {
    position: 'fixed', top: '12px', left: '50%', transform: 'translateX(-50%)', zIndex: '2147483647',
    pointerEvents: 'none', font: '500 12px -apple-system, system-ui, sans-serif', color: '#ECECF1',
    background: 'rgba(15,15,19,0.92)', padding: '7px 14px', borderRadius: '999px',
    boxShadow: '0 6px 24px rgba(0,0,0,0.35)'
  });
  document.documentElement.append(box, tip);

  let current = null;
  const move = (e) => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === box || el === tip || el === document.documentElement || el === document.body) return;
    current = el;
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
  };

  const esc = (s) => CSS.escape(s);
  // Skip generated-looking ids/classes (hashes, CSS-in-JS) that won't survive a reload.
  const stable = (s) => s && s.length < 40 && !/\d{3,}|^(css|sc|jsx|emotion|svelte)-|__[a-z0-9]{5,}$|^[a-z0-9]{6,}$/i.test(s);

  const selectorFor = (el) => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
      if (n.id && stable(n.id) && document.querySelectorAll('#' + esc(n.id)).length === 1) {
        parts.unshift('#' + esc(n.id));
        break;
      }
      let part = n.tagName.toLowerCase();
      const classes = [...n.classList].filter(stable).slice(0, 2);
      if (classes.length) part += '.' + classes.map(esc).join('.');
      const parent = n.parentElement;
      if (parent && n !== document.body) {
        const sameTag = [...parent.children].filter((c) => c.tagName === n.tagName);
        const matching = [...parent.children].filter((c) => { try { return c.matches(part); } catch (_) { return false; } });
        if (matching.length > 1) part += `:nth-of-type(${sameTag.indexOf(n) + 1})`;
      }
      parts.unshift(part);
      if (n === document.body) break;
      try { if (parts.length >= 2 && document.querySelectorAll(parts.join(' > ')).length === 1) break; } catch (_) {}
    }
    return parts.join(' > ');
  };

  const stop = (e) => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
  const cleanup = () => {
    removeEventListener('mousemove', move, true);
    removeEventListener('click', click, true);
    removeEventListener('mousedown', stop, true);
    removeEventListener('mouseup', stop, true);
    removeEventListener('keydown', key, true);
    box.remove();
    tip.remove();
    window.__voidHiderActive = false;
  };
  const click = (e) => {
    stop(e);
    const target = document.elementFromPoint(e.clientX, e.clientY);
    if (target && target !== box && target !== tip && target !== document.documentElement && target !== document.body) current = target;
    if (!current) return;
    const selector = selectorFor(current);
    try { document.querySelector(selector); } catch (_) { cleanup(); post({ cancelled: true }); return; }
    current.style.setProperty('display', 'none', 'important');
    cleanup();
    post({ selector, host: location.hostname });
  };
  const key = (e) => {
    if (e.key === 'Escape') { stop(e); cleanup(); post({ cancelled: true }); }
  };

  addEventListener('mousemove', move, true);
  addEventListener('click', click, true);
  addEventListener('mousedown', stop, true);
  addEventListener('mouseup', stop, true);
  addEventListener('keydown', key, true);
  return 'started';
})()
