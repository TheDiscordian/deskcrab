"use strict";
// FaceCard — the one browser face renderer (specs/face.md, the 2026-08-30
// amendment). The chess table, the OpenRSC spectator, and the standalone
// portrait viewer all load this same file from their own servers (the
// browser_voice_queue.js rule: one neutral asset, several servers, never one
// proxying another). The mechanics live here; POLICY stays on the page —
// captions, pause semantics, which routes exist, and what each size means in
// pixels are the page's own.
//
// What it does:
//   - draws the layered face: base frame, expression overlay, mouth patch;
//   - follows the shared broker read-only (long-poll on seq when the server
//     supports ?after=, plain polling otherwise), with bounded backoff;
//   - moves the mouth from the broker's REAL clip cue tracks — offsets from
//     each clip's playback start, server clock skew corrected — never from
//     text, never from a guessed timer. No clips, no lip movement;
//   - offers a remembered three-step size control: an obvious button that
//     cycles compact/medium/large, persisted per surface in localStorage;
//   - degrades in layers: no manifest -> the page's fixed portrait pair;
//     no broker -> the page's local activity hint; no art at all -> the
//     'unavailable' class and the page hides the card. Never broken chrome.
//
// The page provides inside `root`:
//   <img data-face-base ...>   the always-visible base frame
//   <img data-face-expr ...>   the overlay frame (opacity via .expressive)
// and CSS for [data-face-size="..."], .expressive, .speaking, .unavailable.

(function () {
  function init(opts) {
    const root = opts.root;
    if (!root) return null;
    const base = root.querySelector("[data-face-base]");
    const expr = root.querySelector("[data-face-expr]");
    const fetchOpts = opts.fetchOpts || { cache: "no-store" };
    const sizes = opts.sizes || ["compact", "medium", "large"];
    const sizeKey = opts.sizeKey || "deskcrab-face-size";
    const fallbackExpr = expr ? expr.getAttribute("src") : "";
    const reduced = window.matchMedia
      && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const card = {
      manifest: null,
      state: null,          // last broker state, or null when unavailable
      hint: null,           // the page's local expression hint (activity)
      skewMs: 0,            // broker clock minus page clock
      seq: null,
      stopped: false,
    };

    // ---- remembered size -------------------------------------------------
    function readSize() {
      try {
        const s = localStorage.getItem(sizeKey);
        if (sizes.indexOf(s) >= 0) return s;
      } catch (_) {}
      return opts.defaultSize || sizes[Math.floor(sizes.length / 2)] || sizes[0];
    }
    function applySize(name, persist) {
      if (sizes.indexOf(name) < 0) return;
      root.dataset.faceSize = name;
      if (persist) { try { localStorage.setItem(sizeKey, name); } catch (_) {} }
      if (opts.sizeButton) {
        const label = name.charAt(0).toUpperCase() + name.slice(1);
        opts.sizeButton.textContent = "Face: " + label;
        opts.sizeButton.setAttribute("aria-label",
          "Portrait size: " + name + ". Activate to cycle sizes.");
      }
      if (opts.onSize) opts.onSize(name);
    }
    applySize(readSize(), false);
    if (opts.sizeButton) {
      opts.sizeButton.addEventListener("click", () => {
        const cur = sizes.indexOf(root.dataset.faceSize);
        applySize(sizes[(cur + 1) % sizes.length], true);
      });
    }

    // ---- broken art never shows (face.md rules 10-11) --------------------
    const imgs = [base, expr].filter(Boolean);
    for (const img of imgs) {
      img.addEventListener("error", () => {
        if (imgs.every(x => !x.complete || !x.naturalWidth))
          root.classList.add("unavailable");
      });
      img.addEventListener("load", () => root.classList.remove("unavailable"));
    }

    // ---- the mouth patch (face.md rules 20-24) ---------------------------
    // Built only when the manifest declares visemes; positioned at the
    // manifest's own mouth rect, scaled with the card.
    let mouth = null, mouthRectPct = null, mouthTimer = null;
    function buildMouth() {
      const m = card.manifest;
      if (!m || !m.visemes || !m.size || mouth) return;
      const names = Object.keys(m.visemes);
      if (!names.length) return;
      const rect = m.visemes[names[0]].rect;
      if (!rect || rect.length !== 4) return;
      const [W, H] = m.size;
      mouthRectPct = {
        left: (rect[0] / W) * 100, top: (rect[1] / H) * 100,
        width: ((rect[2] - rect[0]) / W) * 100,
        height: ((rect[3] - rect[1]) / H) * 100,
      };
      mouth = document.createElement("img");
      mouth.alt = "";
      mouth.setAttribute("aria-hidden", "true");
      mouth.dataset.faceMouth = "1";
      mouth.style.cssText = "position:absolute;display:none;"
        + "left:" + mouthRectPct.left + "%;top:" + mouthRectPct.top + "%;"
        + "width:" + mouthRectPct.width + "%;height:" + mouthRectPct.height + "%;";
      root.appendChild(mouth);
      // Preload the patches so the first cue is a swap, not a fetch.
      for (const name of names) {
        const img = new Image();
        img.src = opts.routes.asset(m.visemes[name].asset);
      }
    }
    function brokerNow() { return (Date.now() + card.skewMs) / 1000; }
    function visemeAt(now) {
      const clips = (card.state && card.state.clips) || [];
      for (const c of clips) {
        const t = now - c.start;
        if (t >= 0 && t < c.duration) {
          let cur = "rest";
          for (const cue of c.cues || []) {
            if (cue[0] <= t) cur = cue[1]; else break;
          }
          return cur;
        }
      }
      return "rest";
    }
    function clipsLive() {
      const clips = (card.state && card.state.clips) || [];
      const now = brokerNow();
      return clips.some(c => c.start + c.duration > now);
    }
    let shownViseme = "rest";
    function mouthTick() {
      mouthTimer = null;
      if (card.stopped) return;
      const vis = document.hidden ? "rest" : visemeAt(brokerNow());
      if (vis !== shownViseme) {
        shownViseme = vis;
        if (mouth) {
          const m = card.manifest;
          const spec = m && m.visemes && m.visemes[vis];
          if (vis === "rest" || !spec) {
            mouth.style.display = "none";
          } else {
            const src = opts.routes.asset(spec.asset);
            if (mouth.dataset.src !== src) {
              mouth.src = src;
              mouth.dataset.src = src;
            }
            mouth.style.display = "block";
          }
        }
      }
      if (clipsLive() && !document.hidden) {
        mouthTimer = setTimeout(mouthTick, 90);
      } else if (mouth && shownViseme !== "rest") {
        shownViseme = "rest";
        mouth.style.display = "none";
      }
    }
    function armMouth() {
      if (!mouthTimer && clipsLive()) mouthTick();
      if (!clipsLive() && mouth && shownViseme !== "rest") {
        shownViseme = "rest";
        mouth.style.display = "none";
      }
    }
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) armMouth();
    });

    // ---- the face itself -------------------------------------------------
    function paint() {
      const st = card.state;
      const want = (st && st.expression && st.expression !== "resting")
        ? st.expression : card.hint;
      const m = card.manifest;
      let show = false;
      if (want && m && m.expressions && m.expressions[want]) {
        const src = opts.routes.asset(m.expressions[want].asset);
        if (expr && expr.dataset.face !== src) {
          expr.src = src;
          expr.dataset.face = src;
        }
        show = true;
      } else if (want) {
        // No manifest: the page's fixed pair carries the change.
        if (expr && expr.dataset.face) {
          expr.src = fallbackExpr;
          delete expr.dataset.face;
        }
        show = true;
      } else if (expr && expr.dataset.face) {
        expr.src = fallbackExpr;
        delete expr.dataset.face;
      }
      root.classList.toggle("expressive", !!show);
      root.classList.toggle("speaking", !!(st && st.speaking));
      if (opts.onState) opts.onState(st, card);
    }

    // ---- following the broker (read-only, never a dependency) ------------
    let backoff = 3000;
    function loop() {
      if (card.stopped) return;
      const usable = card.state && card.seq != null;
      const url = opts.routes.state
        + (usable ? (opts.routes.state.indexOf("?") < 0 ? "?" : "&")
                    + "after=" + card.seq : "");
      const t0 = Date.now();
      fetch(url, fetchOpts)
        .then(r => r.json())
        .then(st => {
          backoff = 3000;
          if (st && st.available) {
            const unchanged = usable && st.seq === card.seq;
            card.state = st;
            card.seq = st.seq;
            if (typeof st.now === "number")
              card.skewMs = st.now * 1000 - Date.now();
            paint();
            armMouth();
            // A server that held the request (long-poll) is re-asked at
            // once; one that answered instantly with nothing new is a
            // plain-poll server, and hammering it would be a spin.
            setTimeout(loop,
              (unchanged && Date.now() - t0 < 1000) ? 2500 : 250);
          } else {
            card.state = null;
            card.seq = null;
            paint();
            setTimeout(loop, 3000);
          }
        })
        .catch(() => {
          card.state = null;
          card.seq = null;
          paint();
          setTimeout(loop, backoff);
          backoff = Math.min(backoff * 2, 8000);
        });
    }

    function boot() {
      fetch(opts.routes.manifest, fetchOpts)
        .then(r => (r.ok ? r.json() : null))
        .then(m => {
          if (m && m.assets) {
            card.manifest = m;
            // The base becomes the manifest's own resting frame, and the
            // focal point steers the crop at small sizes.
            const rest = m.expressions && m.expressions.resting;
            if (rest && base) base.src = opts.routes.asset(rest.asset);
            if (m.focal && m.size) {
              const pos = (m.focal[0] / m.size[0]) * 100 + "% "
                + (m.focal[1] / m.size[1]) * 100 + "%";
              for (const img of imgs) img.style.objectPosition = pos;
            }
            for (const spec of Object.values(m.expressions || {})) {
              const img = new Image();
              img.src = opts.routes.asset(spec.asset);
            }
            buildMouth();
            paint();
          }
        })
        .catch(() => {})
        .finally(loop);
    }
    boot();

    return {
      setHint(name) { card.hint = name || null; paint(); },
      setSize(name) { applySize(name, true); },
      getSize() { return root.dataset.faceSize; },
      reducedMotion: reduced,
      stop() { card.stopped = true; },
      _card: card,
    };
  }

  window.FaceCard = { init };
})();
