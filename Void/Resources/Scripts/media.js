// Void — video detection and Picture in Picture, injected at document start in every frame
// (isolated world). Reports media state to the app and exposes window.__voidMedia.
(() => {
  if (window.__voidMedia) return;

  const post = (msg) => {
    try { window.webkit.messageHandlers.voidMedia.postMessage(msg); } catch (_) {}
  };
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // <video> elements, including those in open shadow roots (searched only if needed).
  const collect = (root, out, depth) => {
    root.querySelectorAll('video').forEach((v) => out.push(v));
    if (depth > 0) {
      root.querySelectorAll('*').forEach((el) => { if (el.shadowRoot) collect(el.shadowRoot, out, depth - 1); });
    }
    return out;
  };
  const videos = () => {
    const light = collect(document, [], 0);
    return light.length ? light : collect(document, [], 3);
  };

  const isPlaying = (v) => !v.paused && !v.ended && v.readyState > 2;
  const area = (el) => { const r = el.getBoundingClientRect(); return Math.max(0, r.width) * Math.max(0, r.height); };
  const inPiP = (v) => document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture';
  const audible = (v) => !v.muted && v.volume > 0;

  // The "main" video: playing first, then the largest one.
  const best = () => {
    const list = videos().filter((v) => v.readyState > 0 || v.currentSrc || v.src);
    list.sort((a, b) => (Number(isPlaying(b)) - Number(isPlaying(a))) || (area(b) - area(a)));
    return list[0] || null;
  };

  const state = () => {
    const all = videos();
    const main = best();
    const playing = all.filter((v) => isPlaying(v) && (area(v) > 0 || inPiP(v)));
    return {
      hasVideo: !!main && (main.duration > 0 || isPlaying(main)),
      playing: playing.length > 0,
      audible: playing.some(audible),
      inPiP: all.some(inPiP),
      currentTime: main ? main.currentTime : 0,
      paused: main ? main.paused : true,
      isMainFrame: window === window.top
    };
  };

  let timer = 0;
  const report = (type) => {
    clearTimeout(timer);
    const immediate = /picture|presentation/.test(type);
    timer = setTimeout(() => post(Object.assign({ type }, state())), immediate ? 0 : 120);
  };
  ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange',
   'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']
    .forEach((name) => document.addEventListener(name, () => report(name), true));

  async function enterPiP() {
    const v = best();
    if (!v) return 'fail:no-video';
    if (inPiP(v)) return 'ok:already';
    // Sites can opt out with disablePictureInPicture; the user explicitly asked, so lift it.
    if (v.hasAttribute('disablepictureinpicture')) v.removeAttribute('disablepictureinpicture');
    try { v.disablePictureInPicture = false; } catch (_) {}

    let error = '';
    if (typeof v.requestPictureInPicture === 'function' && document.pictureInPictureEnabled !== false) {
      try {
        await v.requestPictureInPicture();
        return 'ok:standard';
      } catch (e) { error = 'standard:' + (e && e.name); }
    }
    if (typeof v.webkitSetPresentationMode === 'function' &&
        (!v.webkitSupportsPresentationMode || v.webkitSupportsPresentationMode('picture-in-picture'))) {
      try {
        v.webkitSetPresentationMode('picture-in-picture');
        for (let i = 0; i < 15; i++) {
          await wait(100);
          if (inPiP(v)) return 'ok:webkit';
        }
        error += ' webkit:timeout';
      } catch (e) { error += ' webkit:' + (e && e.name); }
    }
    return 'fail:' + (error || 'unsupported');
  }

  async function exitPiP() {
    try { if (document.pictureInPictureElement) await document.exitPictureInPicture(); } catch (_) {}
    videos().forEach((v) => {
      try { if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline'); } catch (_) {}
    });
    return 'ok';
  }

  async function play(volume) {
    const v = best() || videos()[0];
    if (!v) return 'fail:no-video';
    try {
      if (typeof volume === 'number') { v.muted = false; v.volume = volume; }
      // play() can stay pending while buffering: don't wait for it forever.
      const result = await Promise.race([v.play().then(() => 'ok'), wait(3000).then(() => 'pending')]);
      return result;
    } catch (e) { return 'fail:' + (e && e.name); }
  }

  // Announce frames that contain a <video> even before playback (embedded players create
  // it early but load it on click), so ⌘⇧P / the app can target that frame.
  let announced = false;
  const announce = () => {
    if (announced || !videos().length) return false;
    announced = true;
    report('present');
    return true;
  };
  const watchForVideo = () => {
    if (announce() || !document.documentElement) return;
    const observer = new MutationObserver(() => { if (announce()) observer.disconnect(); });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    setTimeout(() => observer.disconnect(), 30000);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchForVideo, { once: true });
  else watchForVideo();

  // Plan B: make the video (or the iframe holding it) fill the viewport, so the web view
  // itself can be shown in Void's floating window. Everything else is hidden, not removed.
  let floated = null;
  function float(on) {
    const STYLE_ID = '__void_float_style';
    if (!on) {
      const style = document.getElementById(STYLE_ID);
      if (style) style.remove();
      document.querySelectorAll('.__void_fl_anc, .__void_fl_target')
        .forEach((el) => el.classList.remove('__void_fl_anc', '__void_fl_target'));
      if (floated && floated.video) floated.video.controls = floated.controls;
      floated = null;
      return 'ok';
    }
    let target = best();
    if (target) {
      floated = { video: target, controls: target.controls };
      target.controls = true;
    } else {
      target = [...document.querySelectorAll('iframe')].sort((a, b) => area(b) - area(a))[0];
      if (!target) return 'fail:no-target';
      floated = { video: null };
    }
    target.classList.add('__void_fl_target');
    for (let p = target.parentElement; p; p = p.parentElement) p.classList.add('__void_fl_anc');
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      html, body { overflow: hidden !important; background: #000 !important; }
      .__void_fl_anc { transform: none !important; filter: none !important; contain: none !important;
                        overflow: visible !important; visibility: visible !important; animation: none !important; }
      body *:not(.__void_fl_anc):not(.__void_fl_target) { visibility: hidden !important; }
      .__void_fl_target { visibility: visible !important; position: fixed !important; inset: 0 !important;
                          width: 100vw !important; height: 100vh !important; max-width: none !important;
                          max-height: none !important; margin: 0 !important; transform: none !important;
                          z-index: 2147483647 !important; object-fit: contain !important; background: #000 !important; }`;
    (document.head || document.documentElement).appendChild(style);
    return 'ok';
  }

  window.__voidMedia = { state, enterPiP, exitPiP, play, float };
})();
