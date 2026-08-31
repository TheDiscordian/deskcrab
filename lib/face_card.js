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

    // Keep every painted layer on one small motion stage.  Moving the mouth
    // independently would make it skate across the face; moving the stage
    // keeps the registered plate, expression, and articulation locked.
    // The stage pivots at the frame's bottom centre (face.md rule 51): she
    // sways like a standing figure over her own weight, never a card rocked
    // around its middle.
    const motion = document.createElement("div");
    motion.dataset.faceMotion = "1";
    motion.style.cssText =
      "position:absolute;inset:0;transform-origin:50% 100%;";
    for (const img of [base, expr].filter(Boolean)) motion.appendChild(img);
    root.appendChild(motion);

    // ---- the motion engine (face.md rules 51-54) -------------------------
    // One rAF loop: grounded root idle (weight sway, breathing, shift),
    // damped-spring secondary regions from the manifest (ringlets and
    // ornaments lag the torso), bounded expressive channels, and one-shot
    // gestures.  Reduced motion, a hidden page, or a manifest without a
    // motion section leaves the portrait perfectly still.
    const TAU = Math.PI * 2;
    const engine = {
      raf: null, last: 0, t: 0,
      channels: { energy: 0.5, agitation: 0, droop: 0 },
      target: { energy: 0.5, agitation: 0, droop: 0 },
      override: null,          // broker/page-supplied channel values (rule 54)
      gesture: null,           // {name, t0}
      gestureSeq: null,        // last broker gesture id seen
      mappedExpr: null,
      regions: [],             // {el, spec, s, v, d}
      root: null,              // manifest motion.root
    };
    function clamp(x, lo, hi) { return Math.min(Math.max(x, lo), hi); }
    function setChannels(vals) {
      for (const k of ["energy", "agitation", "droop"])
        if (vals && typeof vals[k] === "number")
          engine.target[k] = clamp(vals[k], 0, 1);
    }
    const GESTURE_KICKS = {  // spring velocity impulses, pendulum deg/s, bob px/s
      shake: { pend: 34, bob: 7 }, bounce: { pend: 9, bob: -16 },
      perk: { pend: 7, bob: -9 }, nod: { pend: 5, bob: 11 },
    };
    function fireGesture(name) {
      if (reduced || !GESTURE_KICKS[name]) return;
      engine.gesture = { name: name, t0: engine.t };
      for (const r of engine.regions) {
        const kick = GESTURE_KICKS[name];
        const mirror = r.spec.id === "ringlet-right" ? -1 : 1;
        r.v += (r.spec.mode === "pendulum" ? kick.pend * mirror : kick.bob)
          * (0.5 + (r.spec.drive.agitation || 0.5));
      }
      startEngine();
    }
    // The fixed public mapping from the resolved expression (rule 54): it
    // reads only the broker's already-resolved state — never an inference.
    const EXPR_MOTION = {
      resting: { energy: 0.5, agitation: 0, droop: 0 },
      attentive: { energy: 0.7, agitation: 0, droop: 0 },
      focused: { energy: 0.35, agitation: 0, droop: 0 },
      pleased: { energy: 0.85, agitation: 0, droop: 0 },
      caught: { energy: 0.75, agitation: 0.3, droop: 0 },
      annoyed: { energy: 0.6, agitation: 0.65, droop: 0 },
      startled: { energy: 0.8, agitation: 0.45, droop: 0 },
      tired: { energy: 0.35, agitation: 0, droop: 0.7 },
    };
    const EXPR_GESTURE = { annoyed: "shake", pleased: "bounce",
                           startled: "perk" };
    function motionForExpression(name) {
      if (engine.mappedExpr === name) return;
      engine.mappedExpr = name;
      if (engine.override) return;   // her hand outranks the mapping
      setChannels(EXPR_MOTION[name] || EXPR_MOTION.resting);
      if (EXPR_GESTURE[name]) fireGesture(EXPR_GESTURE[name]);
    }
    function buildMotion() {
      const m = card.manifest;
      if (reduced || !m || !m.motion || engine.regions.length) return;
      engine.root = m.motion.root || null;
      const maskOK = window.CSS && CSS.supports
        && (CSS.supports("mask-image", "url(#m)")
            || CSS.supports("-webkit-mask-image", "url(#m)"));
      const rest = m.expressions && m.expressions.resting;
      if (maskOK && rest && Array.isArray(m.motion.regions)) {
        for (const spec of m.motion.regions) {
          if (!m.assets[spec.asset]) continue;
          const wrap = document.createElement("div");
          wrap.dataset.faceRegion = spec.id;
          const murl = "url(\"" + opts.routes.asset(spec.asset) + "\")";
          const px = (spec.pivot[0] / m.size[0]) * 100;
          const py = (spec.pivot[1] / m.size[1]) * 100;
          wrap.style.cssText = "position:absolute;inset:0;pointer-events:none;"
            + "mask-image:" + murl + ";-webkit-mask-image:" + murl + ";"
            + "mask-size:100% 100%;-webkit-mask-size:100% 100%;"
            + "mask-repeat:no-repeat;-webkit-mask-repeat:no-repeat;"
            + "transform-origin:" + px + "% " + py + "%;";
          const img = document.createElement("img");
          img.alt = "";
          img.setAttribute("aria-hidden", "true");
          img.src = opts.routes.asset(rest.asset);
          img.style.cssText =
            "position:absolute;inset:0;width:100%;height:100%;"
            + "object-fit:cover;";
          wrap.appendChild(img);
          motion.appendChild(wrap);
          engine.regions.push({ el: wrap, spec: spec, s: 0, v: 0, d: 0 });
        }
      }
      startEngine();
    }
    function stepEngine(nowMs) {
      engine.raf = null;
      if (card.stopped || document.hidden || reduced) return;
      const dt = clamp((nowMs - engine.last) / 1000 || 0.016, 0.001, 0.05);
      engine.last = nowMs;
      engine.t += dt;
      const t = engine.t, ch = engine.channels, tg = engine.target;
      // Channels glide toward their targets; nothing snaps her posture.
      for (const k in ch) ch[k] += (tg[k] - ch[k]) * Math.min(1, dt / 1.2);
      const R = engine.root || {
        sway_deg: 0.55, sway_period: 7.6, shift_px: 1.8,
        shift_period: 11.0, breath_scale: 0.0045, breath_period: 4.2,
      };
      const e = 0.6 + 0.7 * ch.energy, a = ch.agitation;
      const Ts = R.sway_period / (1 + 1.2 * a);
      let sway = R.sway_deg * e * (1 + 0.9 * a) * (1 - 0.3 * ch.droop)
        * (0.7 * Math.sin(TAU * t / Ts)
           + 0.3 * Math.sin(TAU * t / (Ts * 2.63) + 1.1))
        + a * 0.12 * Math.sin(TAU * t * 7.3);
      let dx = R.shift_px * e * Math.sin(TAU * t / R.shift_period + 0.6)
        + a * 0.5 * Math.sin(TAU * t * 5.1);
      let dy = 2.2 * ch.droop;
      const Tb = R.breath_period * (1 - 0.3 * a + 0.4 * ch.droop);
      const th = TAU * t / Tb;
      const breath = 0.5 - 0.5 * Math.cos(th + 0.45 * Math.sin(th));
      const bs = R.breath_scale * (1 + 0.6 * a) * (0.85 + 0.3 * ch.energy);
      let sy = 1 + bs * breath, sx = 1 - 0.35 * bs * breath;
      let grot = 0;
      if (engine.gesture) {
        const gt = t - engine.gesture.t0, g = engine.gesture.name;
        if (gt > 1.6) engine.gesture = null;
        else if (g === "shake")
          grot = 1.5 * Math.exp(-3.2 * gt) * Math.sin(TAU * 3.5 * gt);
        else if (g === "bounce") {
          dy -= 3.0 * Math.sin(Math.PI * Math.min(gt / 0.7, 1))
            * Math.exp(-2 * gt);
          sy += 0.006 * Math.sin(TAU * gt / 0.7) * Math.exp(-2 * gt);
        } else if (g === "perk") {
          sy += 0.008 * Math.exp(-6 * gt); dy -= 2.5 * Math.exp(-6 * gt);
        } else if (g === "nod")
          dy += 2.2 * Math.sin(TAU * 2.5 * gt) * Math.exp(-3 * gt);
      }
      motion.style.transform = "translate(" + dx.toFixed(2) + "px,"
        + dy.toFixed(2) + "px) rotate(" + (sway + grot).toFixed(3)
        + "deg) scale(" + sx.toFixed(4) + "," + sy.toFixed(4) + ")";
      // Secondary springs: each region tracks its driver and lags it, so
      // what shows is the lag — ringlets trailing the torso, ornaments
      // bobbing against the breath — and at rest the offset is zero, so
      // no seam of doubled artwork can open (rule 53).
      const H = (card.manifest && card.manifest.size)
        ? card.manifest.size[1] : 420;
      for (const r of engine.regions) {
        const sp = r.spec, drv = sp.drive || {};
        let d;
        if (sp.mode === "pendulum") {
          d = (drv.sway || 1) * (sway + grot)
            + a * (drv.agitation || 0) * 0.4 * Math.sin(TAU * t * 3.1
              + sp.pivot[0]);
        } else {
          const lift = (H - sp.pivot[1]) * bs * breath;
          d = -(drv.breath || 1) * lift * 4 + (drv.sway || 0) * dx * 0.4
            + a * (drv.agitation || 0) * 0.5 * Math.sin(TAU * t * 4.3
              + sp.pivot[0]);
        }
        const k = sp.stiffness || 30, c = sp.damping || 4;
        r.v += (k * (d - r.s) - c * r.v) * dt;
        r.s += r.v * dt;
        r.d = d;
        // The spring's lag term rings on kicks and reversals; the breeze
        // term keeps the part gently out of phase with the torso even in
        // calm idle, where a stiff spring would track the slow sway too
        // faithfully to see.  Phase comes from the pivot, so no two
        // regions ever move in lockstep.
        const brz = 1 + 1.2 * a;
        if (sp.mode === "pendulum") {
          const breeze = 0.35 * e * brz
            * Math.sin(TAU * t / 3.7 + sp.pivot[0] * 0.13);
          const lim = (sp.max_deg || 1.2) * (1 + 0.8 * a);
          r.el.style.transform = "rotate("
            + clamp(r.s - d + breeze, -lim, lim).toFixed(3) + "deg)";
        } else {
          const breeze = 0.7 * e * brz
            * Math.sin(TAU * t / 2.6 + sp.pivot[0] * 0.21);
          const lim = (sp.max_px || 2.6) * (1 + 0.8 * a);
          r.el.style.transform = "translate(0,"
            + clamp(r.s - d + breeze, -lim, lim).toFixed(2) + "px)";
        }
      }
      engine.raf = requestAnimationFrame(stepEngine);
    }
    function startEngine() {
      if (reduced || card.stopped || document.hidden) return;
      if (engine.raf == null) {
        engine.last = performance.now();
        engine.raf = requestAnimationFrame(stepEngine);
      }
    }
    if (!reduced) startEngine();

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
    let mouths = [], activeMouth = -1, mouthRectPct = null, mouthTimer = null;
    function buildMouth() {
      const m = card.manifest;
      if (!m || !m.visemes || !m.size || mouths.length) return;
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
      // The lip anchor steers rule 24's morph: transitions scale about the
      // resting lip line, so contours grow and shrink from the same point.
      const anch = (m.mouth && m.mouth.anchor) || null;
      const aoX = anch ? (anch[0] / (rect[2] - rect[0])) * 100 : 50;
      const aoY = anch ? (anch[1] / (rect[3] - rect[1])) * 100 : 50;
      for (let i = 0; i < 2; i++) {
        const mouth = document.createElement("img");
        mouth.alt = "";
        mouth.setAttribute("aria-hidden", "true");
        mouth.dataset.faceMouth = String(i + 1);
        mouth.style.cssText = "position:absolute;display:none;opacity:0;"
          + "left:" + mouthRectPct.left + "%;top:" + mouthRectPct.top + "%;"
          + "width:" + mouthRectPct.width + "%;height:" + mouthRectPct.height + "%;"
          + "pointer-events:none;"
          + "transform-origin:" + aoX + "% " + aoY + "%;"
          + "transition:opacity 100ms ease-out,transform 100ms ease-out;";
        motion.appendChild(mouth);
        mouths.push(mouth);
      }
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
    let shownVisemePainted = "rest";
    function visExtent(name) {
      const m = card.manifest;
      if (m && m.visemes && m.visemes[name] && m.visemes[name].extent)
        return m.visemes[name].extent;
      if (m && m.mouth && m.mouth.rest_extent) return m.mouth.rest_extent;
      return null;
    }
    // The contour interpolation of rule 24: the incoming patch eases from
    // the outgoing contour's measured extent to its own, and the outgoing
    // one eases toward the incoming extent while it fades — a morph about
    // the lip anchor, never a snap between mismatched silhouettes.
    function morphScale(from, to) {
      const a = visExtent(from), b = visExtent(to);
      if (!a || !b) return null;
      return "scale(" + clamp(a[0] / b[0], 0.6, 1.6).toFixed(3) + ","
        + clamp(a[1] / b[1], 0.5, 2.0).toFixed(3) + ")";
    }
    function showViseme(vis) {
      const m = card.manifest;
      const spec = m && m.visemes && m.visemes[vis];
      const from = shownVisemePainted;
      shownVisemePainted = (vis === "rest" || !spec) ? "rest" : vis;
      if (vis === "rest" || !spec) {
        for (const mouth of mouths) {
          mouth.style.opacity = "0";
          if (!reduced) {
            const toRest = morphScale("rest",
              mouth.dataset.vis || from || "rest");
            mouth.style.transform = toRest ? toRest : "";
          }
        }
        activeMouth = -1;
        return;
      }
      const next = reduced ? 0 : (activeMouth === 0 ? 1 : 0);
      const incoming = mouths[next];
      if (!incoming) return;
      const src = opts.routes.asset(spec.asset);
      if (incoming.dataset.src !== src) {
        incoming.src = src;
        incoming.dataset.src = src;
      }
      incoming.dataset.vis = vis;
      incoming.style.display = "block";
      if (reduced) {
        for (const mouth of mouths) mouth.style.opacity = "0";
        incoming.style.opacity = "1";
      } else {
        // Commit the transparent starting contour before easing to the
        // next registered patch.  Both layers stay on the moving stage.
        incoming.style.opacity = "0";
        const start = morphScale(from || "rest", vis);
        incoming.style.transform = start ? start : "";
        void incoming.offsetWidth;
        for (let i = 0; i < mouths.length; i++) {
          if (i === next) continue;
          mouths[i].style.opacity = "0";
          const away = morphScale(vis, mouths[i].dataset.vis || "rest");
          if (away) mouths[i].style.transform = away;
        }
        incoming.style.opacity = "1";
        incoming.style.transform = "scale(1,1)";
      }
      activeMouth = next;
    }
    function mouthTick() {
      mouthTimer = null;
      if (card.stopped) return;
      const vis = document.hidden ? "rest" : visemeAt(brokerNow());
      if (vis !== shownViseme) {
        shownViseme = vis;
        if (mouths.length) showViseme(vis);
      }
      if (clipsLive() && !document.hidden) {
        mouthTimer = setTimeout(mouthTick, 90);
      } else if (mouths.length && shownViseme !== "rest") {
        shownViseme = "rest";
        showViseme("rest");
      }
    }
    function armMouth() {
      if (!mouthTimer && clipsLive()) mouthTick();
      if (!clipsLive() && mouths.length && shownViseme !== "rest") {
        shownViseme = "rest";
        showViseme("rest");
      }
    }
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) { startEngine(); armMouth(); }
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
      // Motion follows the resolved expression through the fixed public
      // mapping, unless the broker's own motion field stands above it
      // (rule 54).  An explicit gesture fires once per gesture id.
      if (st && st.motion && typeof st.motion === "object") {
        engine.override = st.motion;
        setChannels(st.motion);
      } else if (engine.override) {
        engine.override = null;
        engine.mappedExpr = null;   // re-derive from the expression below
      }
      if (st && st.gesture && st.gesture.name
          && st.gesture.id !== engine.gestureSeq) {
        engine.gestureSeq = st.gesture.id;
        fireGesture(st.gesture.name);
      }
      motionForExpression((st && st.expression) || want || "resting");
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
            buildMotion();
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
      // Rule 54's channels, for the page's own hand: bounded values in,
      // one-shot gestures by name.  Values set here stand until cleared.
      setMotion(vals) {
        engine.override = vals || null;
        if (vals) setChannels(vals);
        else engine.mappedExpr = null;
      },
      gesture(name) { fireGesture(name); },
      stop() {
        card.stopped = true;
        if (engine.raf != null) cancelAnimationFrame(engine.raf);
        engine.raf = null;
        showViseme("rest");
      },
      _card: card,
      _engine: engine,
    };
  }

  window.FaceCard = { init };
})();
