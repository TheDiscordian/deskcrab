// Dead clips stay dead — the client shapes of the engineering record
// phone-playback-dies-mid-reply-leaves-a-dead-play, pinned against the
// recorded evidence (specs/phone.md rules 44a-44b):
//
// (a) THE REJECTION-FIRST ORDERING, measured 2026-08-11 on turn db935524
//     clips 3 and 4 and turn e913a586 clip 2: a dead source's play()
//     rejection lands BEFORE the element's error event, playerMeta still
//     matches, err.name reads NotAllowedError — and the client reported
//     "autoplay refused", offered the ▶ button on the very source that
//     cannot load, and then reported "media error 4" for the same clip. One
//     failure must be one report, and no button.
// (b) THE ERROR-FIRST ORDERING must end the same way — and the dead state is
//     terminal: offerPlay refuses the failed source however late it is asked.
// (c) THE 23:39 WEDGE, measured 2026-08-23 on turn 58d64fe9: seven clips
//     offered, seven `requested` reports POSTed, zero /audio fetches, and no
//     terminal report of any kind — the queue sat in its playing state for
//     good. A clip that never starts must be given up on with its own
//     distinct failure report, never a `started` or `completed`, and the
//     queue freed behind it.
//
// Run: node tests/phone_client_deadclip_test.js
//      (or through tests/test_phone_dead_clip.sh, which also feeds shape
//      (c)'s reports through the real server; REPORT_DUMP names the file the
//      wedge's POST bodies are written to for that half)
//
// Lifted from lib/webapp/index.html exactly as tests/phone_client_test.js
// lifts: by name, failing loudly on a rename. The rule-44a/44b helpers are
// lifted when present and stubbed inert when absent, so this file also runs
// against the pre-change client and shows the old behaviour red rather than
// crashing on a missing name.

const fs = require("fs");
const path = require("path");

const HTML = path.join(__dirname, "..", "lib", "webapp", "index.html");
const src = fs.readFileSync(HTML, "utf8");

let PASS = 0, FAIL = 0;
const ok = m => { PASS++; console.log("  ok: " + m); };
const bad = (m, got) => { FAIL++; console.log("  FAIL: " + m + " — got [" + got + "]"); };

function lift(name) {
  const start = src.indexOf(name);
  if (start < 0) throw new Error("not found in index.html: " + name);
  const end = src.indexOf("\n}\n", start);
  if (end < 0) throw new Error("no closing brace for: " + name);
  return src.slice(start, end + 3);
}

function liftBetween(a, b) {
  const s = src.indexOf(a);
  if (s < 0) throw new Error("not found in index.html: " + a);
  const e = src.indexOf(b, s);
  if (e < 0) throw new Error("no end marker after " + a + ": " + b);
  return src.slice(s, e + b.length);
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// The full playback surface: the REAL reportPlay (its dedup under test, post
// stubbed), the REAL offerPlay (its refusal under test, DOM stubbed), both
// queue functions, markStarted with its playing listener, and the page-level
// ended/error listeners. Graces are shrunk through the ctx so the deferred
// verdicts land inside a test's sleeps.
function buildCtx() {
  const posts = [], buttons = [], warns = [], listeners = {};
  const ctx = {
    voiceQueue: [], voicePlaying: false, voiceMuted: false,
    playerMeta: null, playerStarted: false,
    deadClips: new Set(), clipErrorsReported: new Set(),
    clipStartTimer: null, duckedVoice: false,
    REFUSAL_GRACE_MS: 40, CLIP_START_GRACE_MS: 120,
    plays: [],                        // one scripted play() result per clip
    updateTalkBtn: () => {},
    setStatus: () => {},
    console: { warn: m => warns.push(String(m)), log: m => warns.push(String(m)) },
    post: (url, body) => { posts.push(JSON.parse(body)); return Promise.resolve({}); },
    $: () => ({ parentNode: { insertBefore: () => {} } }),
    document: {
      createElement: () => {
        const el = { hidden: true, id: "", textContent: "",
                     addEventListener: () => {} };
        buttons.push(el);
        return el;
      },
    },
    player: {
      src: "", error: null, currentTime: 0,
      addEventListener: (k, fn) => {
        (listeners[k] = listeners[k] || []).push(fn);
      },
      removeAttribute(a) { if (a === "src") this.src = ""; },
      load() {},
      play() {
        const r = ctx.plays.shift();
        // Unscripted: a load that never settles — the wedge's element.
        return r ? r() : new Promise(() => {});
      },
    },
    _posts: posts, _buttons: buttons, _warns: warns,
    _fire: k => (listeners[k] || []).forEach(f => f()),
  };
  // $("playnow") must find no existing button, so offerPlay always creates
  // one this harness can count; the stub above returns a node-alike for the
  // insertBefore call either way.
  ctx.$ = id => (id === "playnow" ? null : { parentNode: { insertBefore: () => {} } });

  let helpers = "";
  for (const n of ["function markClipDead", "function clipDead",
                   "function disarmClipWatchdog", "function armClipWatchdog"]) {
    try { helpers += lift(n) + "\n"; } catch (e) { /* pre-change client */ }
  }
  if (!/function clipDead/.test(helpers)) {
    // Pre-change client: no dead state, no give-up clock. Inert stand-ins
    // keep the lift running so the assertions can show the old behaviour
    // red instead of this harness dying on a missing name.
    Object.assign(ctx, { markClipDead: () => {}, clipDead: () => false,
                         disarmClipWatchdog: () => {}, armClipWatchdog: () => {} });
  }

  const body = helpers +
      lift("function reportPlay") + "\n" +
      lift("function offerPlay") + "\n" +
      lift("function enqueueVoice") + "\n" +
      lift("function playNextVoice") + "\n" +
      liftBetween("function markStarted",
                  'player.addEventListener("playing", markStarted);') + "\n" +
      liftBetween('player.addEventListener("ended"',
                  'player.addEventListener("error"')
        .replace(/player\.addEventListener\("error"$/, "") + "\n" +
      liftBetween('player.addEventListener("error"',
                  "playNextVoice(); updateTalkBtn();\n});");
  ctx._api = new Function("ctx",
      "with (ctx) {\n" + body + "\nreturn {enqueueVoice, playNextVoice, offerPlay, reportPlay};\n}"
  )(ctx);
  return ctx;
}

const offered = ctx => ctx._buttons.filter(b => b.hidden === false);

// --- (a) rejection-first: one media error, no refusal, no button -----------

async function testRejectionFirst() {
  console.log("the dead source, rejection first — one report, no button:");
  const ctx = buildCtx();
  let rej = null;
  ctx.plays = [() => new Promise((_, r) => { rej = r; })];
  ctx._api.enqueueVoice("/audio/d3.opus", { tid: "db935524aa", clip: "3" });
  await sleep(5);
  rej({ name: "NotAllowedError" });      // the rejection lands FIRST
  await sleep(5);                        // …a beat…
  ctx.player.error = { code: 4 };
  ctx._fire("error");                    // …then the element's own error event
  await sleep(150);                      // past the refusal grace

  const errs = ctx._posts.filter(p => p.event === "error" && p.clip === "3");
  if (errs.length === 1 && /media error 4/.test(errs[0].detail))
    ok("exactly one error report, and it is the media error on the clip's own index");
  else bad("a dead source must yield ONE error report, the media error",
           JSON.stringify(ctx._posts));
  if (!ctx._posts.some(p => /autoplay refused/.test(p.detail || "")))
    ok("no autoplay refusal is invented for a source that failed to load");
  else bad("the rejection-first ordering must not report a refusal",
           JSON.stringify(ctx._posts));
  if (offered(ctx).length === 0)
    ok("no ▶ button is offered on the source that cannot load");
  else bad("the ▶ button must never be wired to a dead source", offered(ctx).length);
  if (!ctx.voicePlaying) ok("the queue ends idle, not wedged on the dead clip");
  else bad("voicePlaying must clear once the dead clip is settled", ctx.voicePlaying);
}

// --- (b) error-first: same outcome, and the dead state is terminal ---------

async function testErrorFirst() {
  console.log("");
  console.log("the dead source, error first — same outcome, and the state is terminal:");
  const ctx = buildCtx();
  let rej = null;
  ctx.plays = [() => new Promise((_, r) => { rej = r; })];
  ctx._api.enqueueVoice("/audio/e2.opus", { tid: "e913a586bb", clip: "2" });
  await sleep(5);
  ctx.player.error = { code: 4 };
  ctx._fire("error");                    // the element speaks first this time
  await sleep(5);
  rej({ name: "NotAllowedError" });      // the rejection trails in
  await sleep(150);

  const errs = ctx._posts.filter(p => p.event === "error" && p.clip === "2");
  if (errs.length === 1 && /media error 4/.test(errs[0].detail))
    ok("exactly one error report in this ordering too");
  else bad("error-first must also yield one media-error report",
           JSON.stringify(ctx._posts));
  if (offered(ctx).length === 0)
    ok("and no ▶ button either");
  else bad("no button in the error-first ordering", offered(ctx).length);

  // The state is terminal: however late something asks, the failed source is
  // refused — silently, with the log line as the witness.
  ctx._api.offerPlay("/audio/e2.opus");
  if (offered(ctx).length === 0)
    ok("offerPlay refuses the dead source outright, however late it is asked");
  else bad("offerPlay must refuse a source that already failed", offered(ctx).length);
  if (ctx._warns.some(w => /audio\/e2\.opus/.test(w)))
    ok("and leaves a log line saying so");
  else bad("the refusal must leave a log line", JSON.stringify(ctx._warns));
}

// --- a genuine refusal still gets its button, and is never given up on -----

async function testGenuineRefusalKeepsButton() {
  console.log("");
  console.log("the genuine refusal — still reported, still offered, never shot later:");
  const ctx = buildCtx();
  ctx.plays = [() => Promise.reject({ name: "NotAllowedError" })];
  ctx._api.enqueueVoice("/audio/r0.opus", { tid: "feedc0deaa", clip: "0" });
  await sleep(150);                      // past the refusal grace
  const refused = ctx._posts.filter(p => /autoplay refused/.test(p.detail || ""));
  if (refused.length === 1 && refused[0].clip === "0")
    ok("the refusal is reported, once, for the refused clip");
  else bad("a real refusal must still be reported", JSON.stringify(ctx._posts));
  if (offered(ctx).length === 1)
    ok("and the ▶ button is offered on the source a tap can actually play");
  else bad("the button must still be offered for a real refusal", offered(ctx).length);
  await sleep(300);                      // far past the give-up clock
  if (!ctx._posts.some(p => /never started/.test(p.detail || "")))
    ok("a clip waiting on a tap is not stuck: the give-up clock stands disarmed");
  else bad("the refusal must disarm the give-up clock", JSON.stringify(ctx._posts));
}

// --- (c) the never-started clip: its own failure, never a play claim -------

async function testNeverStartedGivesUp() {
  console.log("");
  console.log("the clip that never starts — given up on, reported as its own failure:");
  const ctx = buildCtx();
  // play() unscripted: pending forever, no media event of any kind.
  ctx._api.enqueueVoice("/audio/w0.opus", { tid: "58d64fe9cc", clip: "0" });
  await sleep(300);                      // past the give-up clock

  const gaveUp = ctx._posts.filter(p => p.event === "error" && p.clip === "0"
                                        && /never started/.test(p.detail));
  if (gaveUp.length === 1)
    ok("the clip is reported as its own distinct failure, once");
  else bad("a clip that never starts must be reported as a failure",
           JSON.stringify(ctx._posts));
  if (!ctx._posts.some(p => p.event === "started" || p.event === "completed"))
    ok("and never as played: no started, no completed, ever");
  else bad("a clip that never sounded must never be reported played",
           JSON.stringify(ctx._posts));
  if (!ctx.voicePlaying && ctx.player.src === "")
    ok("the wedged element is unloaded and the queue freed");
  else bad("the queue must not stay wedged behind the dead load",
           "voicePlaying=" + ctx.voicePlaying + " src=" + ctx.player.src);
  ctx._api.offerPlay("/audio/w0.opus");
  if (offered(ctx).length === 0)
    ok("and the given-up source is dead: no ▶ control for it either");
  else bad("a given-up source must refuse the button", offered(ctx).length);
}

// --- (c) at full size: the 58d64fe9 wedge, seven clips, per-clip failures --

async function testWedgeSevenClips() {
  console.log("");
  console.log("the 58d64fe9 wedge — seven clips, seven per-clip failures, zero play claims:");
  const ctx = buildCtx();
  const TID = "58d64fe9" + "ab".repeat(12);
  // Seven voice events arrive over the turn; the element never progresses —
  // the measured shape: seven `requested` POSTs and, before the fix, nothing
  // else, the stop control showing for good.
  for (let i = 0; i < 7; i++)
    ctx._api.enqueueVoice("/audio/w" + i + ".opus", { tid: TID, clip: String(i) });
  // Each clip gets its own bounded wait in turn; wait out all seven.
  await sleep(7 * ctx.CLIP_START_GRACE_MS + 400);

  const req = ctx._posts.filter(p => p.event === "requested");
  if (req.length === 7) ok("all seven clips report requested, as they always did");
  else bad("seven clips must report requested", req.length);
  const fails = ctx._posts.filter(p => p.event === "error"
                                       && /never started/.test(p.detail));
  const clips = fails.map(p => p.clip).sort().join(",");
  if (fails.length === 7 && clips === "0,1,2,3,4,5,6")
    ok("every one of the seven is reported as its own failure — no bare requested tail");
  else bad("the wedge must yield one explicit failure per clip",
           fails.length + " failures on clips [" + clips + "]");
  if (!ctx._posts.some(p => p.event === "started" || p.event === "completed"))
    ok("and not one claims to have played");
  else bad("no play claim may survive the wedge", JSON.stringify(ctx._posts));
  if (!ctx.voicePlaying && ctx.voiceQueue.length === 0)
    ok("the queue drains instead of believing itself playing for good");
  else bad("the queue must drain", "voicePlaying=" + ctx.voicePlaying +
           " queued=" + ctx.voiceQueue.length);

  // The reports, verbatim, for the shell half: the real server takes these
  // same bodies on /played and must record per-clip failures beside its
  // silent-turn line.
  if (process.env.REPORT_DUMP)
    fs.writeFileSync(process.env.REPORT_DUMP,
        ctx._posts.map(p => JSON.stringify(p)).join("\n") + "\n");
}

// --- one failure is one report, whatever says it twice ---------------------

async function testOneErrorReportPerClip() {
  console.log("");
  console.log("the report dedup — a clip's second error never leaves the page:");
  const ctx = buildCtx();
  ctx._api.reportPlay({ tid: "cafecafe00", clip: "1" }, "error", "autoplay refused");
  ctx._api.reportPlay({ tid: "cafecafe00", clip: "1" }, "error", "media error 4");
  ctx._api.reportPlay({ tid: "cafecafe00", clip: "2" }, "error", "media error 4");
  const errs = ctx._posts.filter(p => p.event === "error");
  if (errs.length === 2 && errs.filter(p => p.clip === "1").length === 1)
    ok("one error per clip per turn: the double signal collapses to the first report");
  else bad("a clip already reported failed must not report again",
           JSON.stringify(errs));
}

(async () => {
  await testRejectionFirst();
  await testErrorFirst();
  await testGenuineRefusalKeepsButton();
  await testNeverStartedGivesUp();
  await testWedgeSevenClips();
  await testOneErrorReportPerClip();
  console.log("");
  console.log(PASS + " passed, " + FAIL + " failed");
  process.exit(FAIL === 0 ? 0 : 1);
})();
