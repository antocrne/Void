// Void — form autofill: remembers what's typed in text fields when a form is sent, and suggests it
// again on fields with the same name (isolated world, every frame). Passwords are not handled here.
// The page shares the DOM and can fake events: only the user's own (isTrusted) count. Otherwise a
// page could focus a hidden field, fake ↓ Entrée and read the values, or plant its own.
(() => {
  if (window.__voidForm) return;

  const post = (msg) => {
    try { window.webkit.messageHandlers.voidForm.postMessage(msg); } catch (_) {}
  };
  const TYPES = new Set(['', 'text', 'email', 'tel', 'url']);
  const SKIP_AUTOCOMPLETE = /^(off|username|.*password.*|one-time-code|cc-.*)$/;
  // Secrets and payment details, wherever they appear in the name; searches and one-time codes
  // as whole words only, so that "postal-code" or "shipping_city" are kept.
  const SECRET_KEY = /otp|captcha|token|card|cvv|cvc|iban|ssn|passw|secret|^cc[-_]/;
  const SKIP_KEY = /(^|[-_.\s])(search|query|q|code|pin)([-_.\s]|$)/;
  const ADDRESS_KEY = /^(postal[-_ ]?code|post[-_ ]?code|zip|zip[-_ ]?code)$/;

  // Sign-in forms belong to the password manager (Void's or an extension such as Proton Pass).
  const inLoginForm = (el) => !!(el.form ? el.form : document).querySelector('input[type=password]');

  const keyFor = (el) => {
    if (!(el instanceof HTMLInputElement) || inLoginForm(el) || !TYPES.has((el.getAttribute('type') || '').toLowerCase())) return null;
    const auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter((t) => t !== 'section-' && !t.startsWith('section-') && t !== 'shipping' && t !== 'billing').pop() || '';
    if (SKIP_AUTOCOMPLETE.test(auto)) return null;
    const key = (auto && auto !== 'on' ? auto : (el.name || el.id || '')).toLowerCase().trim();
    if (key.length < 2 || key.length > 60 || SECRET_KEY.test(key) || (SKIP_KEY.test(key) && !ADDRESS_KEY.test(key))) return null;
    return key;
  };

  // A field shows suggestions only once visible and pointed at or typed into by the user.
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    const style = getComputedStyle(el);
    return style.visibility !== 'hidden' && parseFloat(style.opacity) > 0.1;
  };

  // Fields the user typed into (or filled from the list): only their values are remembered, so
  // a page submitting a form of its own (requestSubmit) can't plant anything.
  const typed = new WeakSet();

  const capture = (root) => {
    const fields = [];
    for (const el of (root || document).querySelectorAll('input')) {
      if (!typed.has(el)) continue;
      const key = keyFor(el);
      const value = (el.value || '').trim();
      if (key && value && value.length <= 200) fields.push({ key, value });
    }
    if (fields.length) post({ type: 'save', fields });
  };
  document.addEventListener('submit', (e) => capture(e.target && e.target.querySelectorAll ? e.target : document), true);
  document.addEventListener('click', (e) => {
    if (!e.isTrusted) return;
    const b = e.target && e.target.closest && e.target.closest('button, input[type=submit]');
    if (b && b.type === 'submit' && b.form) capture(b.form);
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.isTrusted && e.key === 'Enter' && e.target && e.target.form && keyFor(e.target)) capture(e.target.form);
  }, true);

  // ---- suggestions -------------------------------------------------------------------------
  const cache = new Map();   // key -> [values], filled by the app
  let current = null;        // focused input
  let box = null;
  let index = -1;

  const setValue = (el, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };

  const hide = () => { if (box) { box.remove(); box = null; } index = -1; };

  const matches = () => {
    if (!current) return [];
    const text = current.value.toLowerCase();
    return (cache.get(keyFor(current)) || []).filter((v) => v.toLowerCase() !== text && v.toLowerCase().includes(text)).slice(0, 6);
  };

  const render = () => {
    const list = matches();
    if (!current || !list.length || !current.isConnected || !visible(current)) { hide(); return; }
    if (!box) {
      const host = document.createElement('div');
      host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;';
      const root = host.attachShadow({ mode: 'closed' });
      const style = document.createElement('style');
      style.textContent = `
        .l{font:13px -apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;border:1px solid rgba(128,128,128,.35);
           border-radius:8px;box-shadow:0 6px 24px rgba(0,0,0,.25);padding:4px;overflow:hidden;color-scheme:light dark}
        .i{padding:6px 10px;border-radius:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:default}
        .i.on,.i:hover{background:Highlight;color:HighlightText}`;
      const l = document.createElement('div');
      l.className = 'l';
      root.append(style, l);
      host.list = l;
      box = host;
      (document.body || document.documentElement).appendChild(host);
    }
    const r = current.getBoundingClientRect();
    box.style.left = r.left + 'px';
    box.style.top = (r.bottom + 2) + 'px';
    box.list.style.minWidth = Math.max(140, r.width) + 'px';
    box.list.textContent = '';
    list.forEach((v, i) => {
      const d = document.createElement('div');
      d.className = 'i' + (i === index ? ' on' : '');
      d.textContent = v;
      d.addEventListener('mousedown', (e) => { e.preventDefault(); if (e.isTrusted) pick(v); });
      box.list.appendChild(d);
    });
  };

  const pick = (value) => {
    const el = current;
    hide();
    if (el) { el.focus(); setValue(el, value); typed.add(el); }
  };

  // The list for `el`: asked for once per key, then drawn.
  const show = (el) => {
    const key = keyFor(el);
    if (!key || !visible(el)) return;
    current = el;
    if (cache.has(key)) render(); else post({ type: 'suggest', key });
  };

  // A click on a field shows its list as it takes the focus (pointerdown comes first); a field
  // reached otherwise (Tab, or a script's focus()) waits for the user's first key in it.
  let pointed = null;
  for (const type of ['pointerdown', 'mousedown']) {
    document.addEventListener(type, (e) => { if (e.isTrusted) pointed = e.target; }, true);
  }
  document.addEventListener('focusin', (e) => {
    current = null;
    hide();
    if (e.target === pointed) show(e.target);
    pointed = null;
  }, true);
  document.addEventListener('focusout', () => { hide(); }, true);
  document.addEventListener('input', (e) => {
    if (!e.isTrusted) return;
    if (e.target instanceof HTMLInputElement) typed.add(e.target);
    if (e.target === current) { index = -1; render(); } else if (e.target === document.activeElement) show(e.target);
  }, true);
  document.addEventListener('scroll', () => { if (box) render(); }, true);
  document.addEventListener('keydown', (e) => {
    if (!e.isTrusted) return;
    if (!box && e.key === 'ArrowDown' && e.target === document.activeElement) {
      show(e.target);
      return;
    }
    if (!box || e.target !== current) return;
    const list = matches();
    if (e.key === 'ArrowDown') { index = (index + 1) % list.length; render(); e.preventDefault(); }
    else if (e.key === 'ArrowUp') { index = (index - 1 + list.length) % list.length; render(); e.preventDefault(); }
    else if (e.key === 'Enter' && index >= 0) { pick(list[index]); e.preventDefault(); e.stopPropagation(); }
    else if (e.key === 'Escape') { hide(); }
  }, true);

  window.__voidForm = {
    suggestions(key, values) {
      cache.set(key, values);
      if (current && keyFor(current) === key) render();
    }
  };
})();
