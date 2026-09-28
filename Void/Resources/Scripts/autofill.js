// Void — login form detection, password capture and filling (isolated world, every frame).
// Passwords never live in the page: they're sent to the app on submit, stored in the macOS
// keychain, and injected back only after Touch ID / the account password.
(() => {
  if (window.__voidAutofill) return;

  const post = (msg) => {
    try { window.webkit.messageHandlers.voidAutofill.postMessage(msg); } catch (_) {}
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  };
  const passwordFields = () => [...document.querySelectorAll('input[type=password]')].filter(visible);
  const usernameFieldFor = (pw) => {
    const scope = pw.form || document;
    const candidates = [...scope.querySelectorAll(
      'input:not([type]), input[type=text], input[type=email], input[type=tel]')].filter(visible);
    let pick = null;
    for (const c of candidates) {
      if (c.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) pick = c;
    }
    return pick || candidates.find((c) => /user|mail|login|name|ident/i.test(c.name + c.id + c.autocomplete)) || null;
  };

  let announced = false;
  const check = () => {
    if (announced) return;
    const hasUsername = document.querySelector('input[autocomplete=username], input[type=email]');
    if (passwordFields().length || (hasUsername && visible(hasUsername))) {
      announced = true;
      post({ type: 'form', host: location.hostname });
    }
  };

  let lastCapture = 0;
  const capture = () => {
    const pw = passwordFields().find((p) => p.value);
    if (!pw) return;
    const now = Date.now();
    if (now - lastCapture < 1500) return;
    lastCapture = now;
    const user = usernameFieldFor(pw);
    post({ type: 'submit', host: location.hostname, username: user ? user.value : '', password: pw.value });
  };

  document.addEventListener('submit', capture, true);
  document.addEventListener('click', (e) => {
    const button = e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
    if (!button) return;
    const text = (button.textContent || button.value || '') + ' ' + (button.id || '') + ' ' + (button.name || '');
    if (button.type === 'submit' || /log ?in|sign ?in|connexion|se connecter|continuer|continue|next|suivant/i.test(text)) capture();
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target && e.target.type === 'password') capture();
  }, true);

  const setValue = (el, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };

  window.__voidAutofill = {
    fill(username, password) {
      const pw = passwordFields()[0];
      const user = pw ? usernameFieldFor(pw)
        : [...document.querySelectorAll('input[autocomplete=username], input[type=email]')].find(visible);
      if (user && username) setValue(user, username);
      if (pw && password) setValue(pw, password);
      return (pw || user) ? 'ok' : 'fail';
    }
  };

  const observer = new MutationObserver(() => {
    if (announced) { observer.disconnect(); return; }
    clearTimeout(observer.timer);
    observer.timer = setTimeout(check, 400);
  });
  check();
  if (!announced && document.documentElement) {
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }
})();
