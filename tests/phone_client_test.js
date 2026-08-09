// Drives the phone client's two loops — streamTurn and startWatch — against
// stubs, by lifting them out of lib/webapp/index.html and evaluating them with
// every free name supplied. The page is one file with no module boundary, so
// this is the only way to run its logic without a browser; the extraction is
// by function name, and a rename here fails loudly rather than silently
// testing nothing.
//
// Run: node tests/phone_client_test.js   (or through tests/test_phone_client.sh)
//
// The two failures these were written for, both measured 2026-08-07:
//
// 1. THE WEDGE. streamTurn awaited reader.read() with no AbortController and
//    no idle timer, and consulted its 15-minute deadline only inside the
//    catch. A stalled SSE socket therefore never threw, never returned, and
//    held `busy` set for good — recording refused, the reset redraw refused.
//    Live: 17:16:35 POST /say, no reconnect ever, ended by a hand reload at
//    17:21:00. 74 hand reloads in 28 hours.
//
// 2. THE SPIN. A /watch reset arriving while busy slept 2 s and continued —
//    but the cursor and gen were assigned AFTER the continue, so the next poll
//    re-asked with the same stale gen, which the server answers instantly.
//    Twelve identical polls in 23 seconds, and nothing drawn. The trigger is
//    structural: compact_convo runs inside every phone turn, and compaction is
//    exactly what changes the gen.

const fs = require("fs");
const path = require("path");

const HTML = path.join(__dirname, "..", "lib", "webapp", "index.html");
const src = fs.readFileSync(HTML, "utf8");

let PASS = 0, FAIL = 0;
const ok = m => { PASS++; console.log("  ok: " + m); };
const bad = (m, got) => { FAIL++; console.log("  FAIL: " + m + " — got [" + got + "]"); };

// Everything from `<name>` to the first line that is a bare `}` — the page's
// top-level functions are written at column zero.
function lift(name) {
  const start = src.indexOf(name);
  if (start < 0) throw new Error("not found in index.html: " + name);
  const end = src.indexOf("\n}\n", start);
  if (end < 0) throw new Error("no closing brace for: " + name);
  return src.slice(start, end + 3);
}

function build(names, ctx) {
  const body = names.map(lift).join("\n");
  const exports = names.map(n => n.replace(/^(async )?function /, "").replace(/\(.*/, ""))
                       .filter(n => /^[A-Za-z_$][\w$]*$/.test(n));
  // Non-strict on purpose: `with` is what lets the lifted code read and WRITE
  // the page-level lets (busy, cursor, gen, needReseed) as this harness's own.
  return new Function("ctx", "with (ctx) {\n" + body +
                      "\nreturn {" + exports.join(",") + "};\n}")(ctx);
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// --- 1: streamTurn does not wedge on a socket that stops delivering --------

async function testStreamTurn() {
  console.log("streamTurn — a stalled socket is cut, not waited on forever:");

  let reconnects = 0;
  const ctx = {
    IDLE_MS: 300,                      // the page ships 45000; this test cannot wait
    randomHex: () => "abc123",
    setStatus: (s) => { if (s === "reconnecting…") reconnects++; },
    showThought: () => {},
    enqueueVoice: () => {},
    fetch: null,
  };
  const fast = new Function("ctx", "with (ctx) {\n" +
      lift("async function streamTurn").replace(/STREAM_IDLE_MS/g, "IDLE_MS") +
      "\nreturn {streamTurn};\n}")(ctx);

  // A socket that opens, delivers nothing, and never closes. Only the abort
  // ends it — which is the whole point.
  let opened = 0;
  ctx.fetch = async (url, opts) => {
    opened++;
    if (opened > 1) {
      // The retry answers properly, so the test proves the reconnect resumes
      // the turn rather than merely giving up on it.
      return {
        ok: true, status: 200,
        body: { getReader: () => ({
          read: async () => ({ value: new TextEncoder().encode(
              'data: {"kind":"done","spoken":"the answer"}\n\n'), done: false }),
        }) },
      };
    }
    return {
      ok: true, status: 200,
      body: { getReader: () => ({
        read: (opts && opts.signal)
          ? () => new Promise((res, rej) => {
              opts.signal.addEventListener("abort", () => rej(new Error("aborted")));
            })
          : () => new Promise(() => {}),   // pre-fix: nothing ever settles
      }) },
    };
  };

  const started = Date.now();
  const res = await Promise.race([
    fast.streamTurn("hello", {}),
    sleep(6000).then(() => ({ error: "HARNESS TIMEOUT" })),
  ]);
  const took = Date.now() - started;

  if (res && res.spoken === "the answer")
    ok("the turn completes over a reconnect (" + took + "ms, " + reconnects + " reconnects)");
  else
    bad("a stalled stream must be cut and retried, not awaited forever",
        (res && (res.error || JSON.stringify(res))) || "nothing");
  if (reconnects > 0) ok("the idle abort is reported as a reconnect, not an error page");
  else bad("a cut socket should say reconnecting", reconnects);
}

// --- 2: the deadline is consulted outside the catch ------------------------

async function testDeadline() {
  console.log("");
  // A guard, not a repro: it passes on the pre-fix client too, because with
  // the socket ending cleanly the throw path reaches the deadline anyway. It
  // is here so the ceiling cannot quietly become unreachable later.
  console.log("streamTurn — a turn that never delivers a reply ends at the ceiling:");
  const ctx = {
    randomHex: () => "abc123",
    setStatus: () => {},
    showThought: () => {},
    enqueueVoice: () => {},
    // Answers cleanly every time, forever: nothing ever throws, so a deadline
    // that is only read inside the catch is never read at all.
    fetch: async () => ({
      ok: true, status: 200,
      body: { getReader: () => ({ read: async () => ({ done: true }) }) },
    }),
  };
  const body = lift("async function streamTurn")
      .replace("15 * 60 * 1000", "150")      // a ceiling this test can reach
      .replace(/STREAM_IDLE_MS/g, "IDLE_MS");
  const api = new Function("ctx", "with (ctx) {\n" + body + "\nreturn {streamTurn};\n}")(
      Object.assign(ctx, { IDLE_MS: 5000 }));
  const res = await Promise.race([
    api.streamTurn("hello", {}),
    sleep(5000).then(() => ({ error: "HARNESS TIMEOUT" })),
  ]);
  if (res && /gave up/.test(res.error || "") && !/HARNESS/.test(res.error))
    ok("a turn that is alive but going nowhere ends at the ceiling");
  else
    bad("the deadline must be checked on the loop, not only after a throw",
        (res && (res.error || JSON.stringify(res))) || "never returned");
}

// --- 2b: keepalives alone do not hold the client past the deadline ---------
//
// THE SURVIVING HALF OF C10. The idle timer is reset by ANY bytes, and the
// server pings every ~15 s exactly so a healthy link always carries bytes. A
// turn whose done event will never come (the turn thread wedged server-side)
// therefore never throws, never EOFs, and never returns: no timer fires, the
// outer loop is never re-entered, and the deadline — checked only there —
// might as well not exist. `busy` holds until a hand reload, with the status
// stuck on the last thing shown: "thinking…".

async function testPingsAreNotProgress() {
  console.log("");
  console.log("streamTurn — a stream of nothing but pings ends at the ceiling:");
  const enc = new TextEncoder();
  const ctx = {
    IDLE_MS: 60000,                    // far above the ceiling: the idle abort
    randomHex: () => "abc123",         // must NOT be what saves this
    setStatus: () => {},
    showThought: () => {},
    enqueueVoice: () => {},
    turnCtl: null, lastTurnProgress: 0,
    // Pings forever: bytes keep arriving, no frame ever parses to an event.
    fetch: async () => ({
      ok: true, status: 200,
      body: { getReader: () => ({
        read: () => new Promise(res => setTimeout(
          () => res({ value: enc.encode(": ping\n\n"), done: false }), 40)),
      }) },
    }),
  };
  const body = lift("async function streamTurn")
      .replace("15 * 60 * 1000", "500")   // the give-up, reachable in a test
      .replace(/STREAM_IDLE_MS/g, "IDLE_MS");
  const api = new Function("ctx", "with (ctx) {\n" + body + "\nreturn {streamTurn};\n}")(ctx);
  const started = Date.now();
  const res = await Promise.race([
    api.streamTurn("hello", {}),
    sleep(4000).then(() => ({ error: "HARNESS TIMEOUT" })),
  ]);
  const took = Date.now() - started;
  if (res && /gave up/.test(res.error || "") && !/HARNESS/.test(res.error))
    ok("a doneless turn on a healthy link is given up on (" + took + "ms)");
  else
    bad("pings must reset the idle timer but never the deadline",
        (res && (res.error || JSON.stringify(res))) || "never returned");
}

// --- 2c: real events DO push the deadline — a long turn is never cut off ---

async function testProgressExtendsDeadline() {
  console.log("");
  console.log("streamTurn — a turn still sending events outlives the original ceiling:");
  const enc = new TextEncoder();
  let sent = 0;
  const ctx = {
    IDLE_MS: 60000,
    randomHex: () => "abc123",
    setStatus: () => {},
    showThought: () => {},
    enqueueVoice: () => {},
    turnCtl: null, lastTurnProgress: 0,
    // Eight thinking events 100 ms apart — 800 ms of turn against a 400 ms
    // ceiling — then the reply. Only a deadline measured from the LAST event
    // lets this finish.
    fetch: async () => ({
      ok: true, status: 200,
      body: { getReader: () => ({
        read: () => new Promise(res => setTimeout(() => {
          sent++;
          const frame = sent <= 8
            ? 'data: {"kind":"thinking","text":"step ' + sent + '"}\n\n'
            : 'data: {"kind":"done","spoken":"the long haul"}\n\n';
          res({ value: enc.encode(frame), done: false });
        }, 100)),
      }) },
    }),
  };
  const body = lift("async function streamTurn")
      .replace("15 * 60 * 1000", "400")
      .replace(/STREAM_IDLE_MS/g, "IDLE_MS");
  const api = new Function("ctx", "with (ctx) {\n" + body + "\nreturn {streamTurn};\n}")(ctx);
  const res = await Promise.race([
    api.streamTurn("hello", {}),
    sleep(4000).then(() => ({ error: "HARNESS TIMEOUT" })),
  ]);
  if (res && res.spoken === "the long haul")
    ok("every event pushed the deadline; the working turn was never cut");
  else
    bad("a wall-clock deadline cuts off long turns that are visibly working",
        (res && (res.error || JSON.stringify(res))) || "never returned");
}

// --- 2d: the watchdog returns the page to idle when nothing else does ------

async function testWatchdog() {
  console.log("");
  console.log("the watchdog — busy with no progress is forced back to idle:");
  let aborted = 0;
  const statuses = [];
  const ctx = {
    busy: true,
    turnSeq: 1,
    lastTurnProgress: Date.now(),
    turnCtl: { abort: () => { aborted++; } },
    talk: { classList: { remove: () => {} } },
    updateTalkBtn: () => {},
    setStatus: s => statuses.push(s),
  };
  const body = lift("function armTurnWatchdog")
      .replace("17 * 60 * 1000", "250")   // the stall ceiling
      .replace("30 * 1000", "50");        // the poll
  const api = new Function("ctx", "with (ctx) {\n" + body + "\nreturn {armTurnWatchdog};\n}")(ctx);
  api.armTurnWatchdog(1);

  await sleep(150);
  if (ctx.busy) ok("fresh progress keeps it quiet — no reset under a working turn");
  else bad("the watchdog must not fire while progress is fresh", "busy cleared early");

  await sleep(400);
  if (!ctx.busy) ok("past the ceiling the page is returned to idle");
  else bad("busy must not survive the stall ceiling", "busy still set");
  if (aborted > 0) ok("and the in-flight stream is aborted, not orphaned");
  else bad("the stalled fetch must be aborted", aborted);
  if (statuses.some(s => /stalled/.test(s))) ok("with a status that says what happened");
  else bad("the reset must be announced", statuses.join(" | ") || "no status");
}

// --- 3: a /watch reset while busy adopts the new incarnation ---------------

async function testWatchReset() {
  console.log("");
  console.log("/watch — a reset that lands mid-turn is deferred, never spun on:");

  const polls = [];
  let reseeds = 0;
  const ctx = {
    watching: false,
    needReseed: false,
    busy: true,                 // a turn is in flight
    cursor: 17,
    gen: "STALE",
    wakeSeen: "",
    playSeen: "",
    voiceMuted: false,
    reseed: async () => { reseeds++; ctx.cursor = 99; ctx.gen = "FRESH"; },
    renderRemote: () => {},
    enqueueVoice: () => {},
    fetch: async (q) => {
      polls.push(q);
      await sleep(20);
      // The server answers a stale gen instantly, every time it is asked.
      if (ctx.gen !== "FRESH")
        return { ok: true, json: async () => ({ n: 21, gen: "FRESH", turns: [], reset: true }) };
      return { ok: true, json: async () => ({ n: 21, gen: "FRESH", turns: [] }) };
    },
  };
  const api = build(["async function startWatch"], ctx);
  api.startWatch();

  // Long enough to catch the spin: the old handling slept 2 s and re-asked
  // with the same gen, so a shorter window would see one poll either way and
  // prove nothing.
  await sleep(2600);
  const stale = polls.filter(q => /gen=STALE/.test(q)).length;
  if (stale === 1) ok("the stale gen is asked exactly once, then dropped");
  else bad("re-asking with a gen the server rejects is the spin", stale + " stale polls");
  if (ctx.needReseed) ok("the redraw is remembered rather than run over the live turn");
  else bad("a reset while busy must queue a redraw", "needReseed=" + ctx.needReseed);
  if (reseeds === 0) ok("and nothing was redrawn while the turn was in flight");
  else bad("the exchange in flight must not be wiped", reseeds + " reseeds mid-turn");

  ctx.busy = false;            // the turn lands
  await sleep(300);
  if (reseeds === 1) ok("the queued redraw runs as soon as the turn lands");
  else bad("the deferred redraw must actually happen", reseeds + " reseeds");
  if (!ctx.needReseed) ok("and is not repeated on every poll after that");
  else bad("the flag must clear", "needReseed still set");
}

// --- 3b: the mute is persistent and lands on BOTH audio elements -----------
//
// Spec rule 38. The switch exists for a phone that fires in a public pocket:
// one control silences everything the page can sound — the voice clips
// through #player and a handed piece through #music — its state survives a
// reload through localStorage, and it silences rather than suppresses, so
// nothing queued is dropped and nothing replays on unmute.

function muteCtx(stored) {
  const store = { v: stored };
  const btn = { textContent: "", title: "", cls: {} };
  btn.classList = { toggle: (c, on) => { btn.cls[c] = !!on; } };
  return {
    muted: false,
    player: { muted: false },
    music: { muted: false },
    $: () => btn,
    setStatus: () => {},
    localStorage: { getItem: () => store.v,
                    setItem: (k, v) => { store.v = v; } },
    _btn: btn, _store: store,
  };
}

async function testMutePersisted() {
  console.log("");
  console.log("the mute — a stored mute lands on both elements, and the toggle persists:");
  const ctx = muteCtx("1");
  const api = build(["function applyMute", "function initMute",
                     "function toggleMute"], ctx);

  api.initMute();
  if (ctx.muted && ctx.player.muted && ctx.music.muted)
    ok("a reload with the mute stored silences the voice AND the music");
  else
    bad("the stored mute must land on both audio elements",
        "muted=" + ctx.muted + " player=" + ctx.player.muted + " music=" + ctx.music.muted);
  if (ctx._btn.textContent === "\u{1F507}" && ctx._btn.cls.muted === true)
    ok("and the button wears the muted look — obvious at a glance");
  else
    bad("the muted state must be visible on the button",
        ctx._btn.textContent + " cls=" + JSON.stringify(ctx._btn.cls));

  api.toggleMute();
  if (!ctx.muted && !ctx.player.muted && !ctx.music.muted)
    ok("the toggle unmutes both elements together");
  else
    bad("unmuting must reach both elements",
        "muted=" + ctx.muted + " player=" + ctx.player.muted + " music=" + ctx.music.muted);
  if (ctx._store.v === "0")
    ok("and the choice is written back, so it survives the next reload");
  else
    bad("the toggle must persist", ctx._store.v);
}

// --- 3c: the transport for a handed piece ----------------------------------
//
// Spec rule 36: a piece handed with `crab play` gets a visible transport —
// the name, the native play/pause and seek — with its own dismissal, playing
// beside the voice rather than through its queue.

async function testMediaTransport() {
  console.log("");
  console.log("the transport — a handed piece is shown by name, muted state and all:");
  const bar = { hidden: true }, title = { textContent: "" };
  let played = 0;
  const music = {
    muted: false, src: "", paused: false,
    play() { played++; return { catch: () => {} }; },
    pause() { this.paused = true; },
    removeAttribute(a) { if (a === "src") this.src = ""; },
    load() {},
  };
  const ctx = {
    muted: true,
    music,
    $: id => (id === "media" ? bar : title),
  };
  const api = build(["function showMedia", "function closeMedia"], ctx);

  api.showMedia({ id: "p1", url: "/media/tok", title: "night piece" });
  if (title.textContent === "night piece") ok("the piece's name is on the bar");
  else bad("the transport must carry the name", title.textContent);
  if (!bar.hidden) ok("the transport is visible");
  else bad("the transport must be shown", "still hidden");
  if (music.src === "/media/tok") ok("the element points at the served url");
  else bad("src must be the media url", music.src);
  if (music.muted) ok("a muted page hands a muted element — the mute holds on arrival");
  else bad("the mute must land on media arriving after it was set", music.muted);
  if (played === 1) ok("playback was attempted (a refusal falls to the native ▶)");
  else bad("play must be attempted exactly once", played);

  api.closeMedia();
  if (bar.hidden && music.paused && !music.src)
    ok("dismissal pauses, unloads, and hides");
  else
    bad("closeMedia must pause, unload, and hide",
        "hidden=" + bar.hidden + " paused=" + music.paused + " src=" + music.src);
}

// --- 3d: /watch fires the transport once per id, and never on the seed -----

function watchPlayCtx(playSeen, polls, onShow) {
  return {
    watching: false, needReseed: false, busy: false,
    cursor: 0, gen: "G", wakeSeen: "", playSeen, voiceMuted: false,
    reseed: async () => {},
    renderRemote: () => {},
    enqueueVoice: () => {},
    showMedia: onShow,
    fetch: async (q) => {
      polls.push(q);
      await sleep(20);
      return { ok: true, json: async () => (
        { n: 0, gen: "G", turns: [],
          play: { id: "p1", url: "/media/tok", title: "night piece" } }) };
    },
  };
}

async function testWatchPlay() {
  console.log("");
  console.log("/watch — a play event fires the transport once, and a seeded id never:");

  const polls = [];
  let shown = 0;
  const ctx = watchPlayCtx("", polls, () => { shown++; });
  build(["async function startWatch"], ctx).startWatch();
  await sleep(700);
  if (shown === 1) ok("one id, one transport — repeats of it start nothing");
  else bad("the same play id must not re-fire the transport", shown + " times");
  if (ctx.playSeen === "p1") ok("the cursor took the id");
  else bad("playSeen must adopt the delivered id", ctx.playSeen);
  if (polls.filter(q => /playseen=p1/.test(q)).length > 0)
    ok("and later polls acknowledge it back to the server");
  else
    bad("the ack must ride the next poll", polls[polls.length - 1]);

  // The seeded page: /context said this pointer predates the load (rule 37),
  // so the same id arriving on /watch is old news and starts nothing.
  let blared = 0;
  build(["async function startWatch"],
        watchPlayCtx("p1", [], () => { blared++; })).startWatch();
  await sleep(400);
  if (blared === 0) ok("a freshly loaded page never blares a pending hand-off");
  else bad("the seeded id must be treated as already seen", blared + " shows");
}

// --- 4: a rewrite of the record never wipes what is already on screen ------
//
// THE BLANKING, measured live 2026-08-07 23:40. The conversation had been idle
// since 22:18, so the next turn rotated the whole file to the archive and
// started a fresh one holding that turn alone. /watch reported the gen change
// as `reset`, reseed called logEl.replaceChildren() and redrew from the new
// file — and the phone's entire visible conversation went with it, leaving the
// one sentence just spoken. Nothing was lost from disk. It was lost from in
// front of him, which is the only copy he was reading.
//
// A compaction does the same thing more gently (the new file still holds most
// of the conversation), which is why this went unnoticed until a rotation made
// the new file nearly empty.

// Enough DOM to run the render path: append/prepend/replaceChildren, a class
// selector, and text. No browser, and no jsdom dependency for a page that is
// deliberately one file of stdlib-shaped code.
function domStub() {
  const mk = tag => ({
    tag, id: "", className: "", textContent: "", children: [],
    append(...n) { this.children.push(...n); },
    prepend(...n) { this.children.unshift(...n); },
    replaceChildren(...n) { this.children = n.slice(); },
    scrollIntoView() {},
    querySelectorAll(sel) {
      const want = sel.split(",").map(s => s.trim().replace(/^\./, ""));
      const out = [];
      (function walk(node) {
        for (const c of node.children) {
          if (want.some(w => (" " + c.className + " ").indexOf(" " + w + " ") >= 0))
            out.push(c);
          walk(c);
        }
      })(this);
      return out;
    },
  });
  return { document: { createElement: mk }, logEl: mk("div") };
}

// The page as he sees it, top to bottom.
function shownOn(logEl) {
  const out = [];
  (function walk(node) {
    for (const c of node.children) {
      const cls = " " + c.className + " ";
      if (cls.indexOf(" you ") >= 0) out.push("user:" + c.textContent);
      else if (cls.indexOf(" reply ") >= 0) out.push("asst:" + c.textContent);
      else if (cls.indexOf(" rewound ") >= 0) out.push("<rule>");
      walk(c);
    }
  })(logEl);
  return out;
}

function clientFor(served) {
  const dom = domStub();
  const ctx = {
    document: dom.document,
    logEl: dom.logEl,
    attachDisplay: () => {},
    pendingUser: null, pendingReply: null,
    cursor: 12, gen: "OLD",
    fetch: async () => ({ json: async () => served() }),
  };
  const api = build([
    "function norm", "function turnKey", "function appendTurns",
    "function renderSeed", "function renderedKeys", "function renderCarried",
    "async function reseed",
  ], ctx);
  return { api, ctx, dom };
}

const U = t => ({ role: "user", text: t });
const A = t => ({ role: "assistant", text: t });

async function testReseedKeepsScrollback() {
  console.log("");
  console.log("/context redraw — a rewritten record keeps the conversation on screen:");

  // What he had been reading all evening.
  const evening = [U("how did the backup go"), A("it finished clean"),
                   U("and the disk"), A("nearly full, in fact")];
  // What the file holds after the rotation: one exchange, said at the laptop
  // while the phone sat idle. None of it has ever been on this page.
  let served = { n: 2, gen: "NEW", turns: [U("you awake"), A("evidently")] };

  const { api, ctx } = clientFor(() => served);
  api.renderSeed({ summary: "", turns: evening });
  const before = shownOn(ctx.logEl);
  if (before.length !== 4) bad("the harness must start with four bubbles", before.join(" | "));

  await api.reseed();
  const after = shownOn(ctx.logEl);

  const kept = before.every(b => after.indexOf(b) >= 0);
  if (kept) ok("every turn he could already read is still on the page");
  else bad("a reset must not wipe the visible conversation", after.join(" | "));

  if (after.indexOf("<rule>") === 4) ok("a divider marks where the record was rewritten");
  else bad("the carried-over turns need a divider under them", after.join(" | "));

  if (after.slice(5).join(" | ") === "user:you awake | asst:evidently")
    ok("and the new file's turns are drawn under it, in order");
  else bad("the rewritten file's turns must follow the divider", after.slice(5).join(" | "));

  if (ctx.gen === "NEW" && ctx.cursor === 2) ok("the new incarnation is adopted");
  else bad("cursor and gen must follow the rewrite", ctx.cursor + "/" + ctx.gen);
}

async function testReseedDedupes() {
  console.log("");
  console.log("/context redraw — an overlapping payload draws nothing twice:");

  // Compaction: the two oldest turns are folded into a summary, the rest of
  // the file is exactly what the page is already showing, and one new exchange
  // arrived with the rewrite.
  const shown = [U("q1"), A("a1"), U("q2"), A("a2")];
  const served = { n: 9, gen: "NEW", summary: "they talked about q1",
                   turns: [U("q2"), A("a2"), U("q3"), A("a3")] };

  const { api, ctx } = clientFor(() => served);
  api.renderSeed({ summary: "", turns: shown });
  await api.reseed();
  const after = shownOn(ctx.logEl);

  const q2 = after.filter(b => b === "user:q2").length;
  const a2 = after.filter(b => b === "asst:a2").length;
  if (q2 === 1 && a2 === 1) ok("a turn on both sides of the rewrite appears once");
  else bad("the overlap must be deduped, not re-drawn", "q2 x" + q2 + ", a2 x" + a2);

  if (after.join(" | ") === "user:q1 | asst:a1 | user:q2 | asst:a2 | <rule> | user:q3 | asst:a3")
    ok("the page reads as one conversation, oldest first");
  else bad("the carried and the fresh must not interleave", after.join(" | "));

  const sum = after.filter(b => /they talked about/.test(b)).length;
  if (sum === 0) ok("the summary is not drawn over turns that are still visible");
  else bad("a condensation of visible turns is noise", sum + " summaries");
}

async function testReseedQuietWhenNothingNew() {
  console.log("");
  console.log("/context redraw — a rotation with nothing new is invisible:");

  // The archival case as it usually lands: the fresh file holds only the
  // exchange this phone just had, which is already drawn.
  const shown = [U("hello beatrice"), A("like myself, obviously")];
  const served = { n: 2, gen: "NEW", turns: [U("hello beatrice"), A("like myself, obviously")] };

  const { api, ctx } = clientFor(() => served);
  api.renderSeed({ summary: "", turns: shown });
  const before = shownOn(ctx.logEl).join(" | ");
  await api.reseed();
  const after = shownOn(ctx.logEl).join(" | ");

  if (after === before) ok("the page is untouched — no wipe, and no divider either");
  else bad("a rotation that shows him nothing new must change nothing", after);
}

async function testReseedRepeatedTurns() {
  console.log("");
  console.log("/context redraw — the same sentence said twice stays twice:");

  const shown = [U("help"), A("here it is"), U("help"), A("here it is")];
  // He asked a third time; the first two are the ones already on the page.
  const served = { n: 6, gen: "NEW",
                   turns: [U("help"), A("here it is"), U("help"), A("here it is"),
                           U("help"), A("here it is")] };

  const { api, ctx } = clientFor(() => served);
  api.renderSeed({ summary: "", turns: shown });
  await api.reseed();
  const after = shownOn(ctx.logEl);

  const n = after.filter(b => b === "user:help").length;
  if (n === 3) ok("identity is counted, not merely matched");
  else bad("a repeated sentence must not collapse into one", n + " copies of it");
}

async function testReseedEmptyPage() {
  console.log("");
  console.log("/context redraw — with nothing on screen it is the plain redraw:");

  const served = { n: 4, gen: "NEW", summary: "earlier: the backup",
                   turns: [U("and now"), A("all clear")] };
  const { api, ctx } = clientFor(() => served);
  await api.reseed();
  const after = shownOn(ctx.logEl);

  if (after.join(" | ") === "user:and now | asst:all clear")
    ok("the fresh context is drawn");
  else bad("an empty page must still be seeded by a reset", after.join(" | "));

  const seeded = ctx.logEl.children.some(c => c.id === "seed");
  if (seeded) ok("as a seed block, summary and all — there was no scrollback to keep");
  else bad("the empty case keeps the summary", "no seed block");
}

(async () => {
  await testStreamTurn();
  await testDeadline();
  await testPingsAreNotProgress();
  await testProgressExtendsDeadline();
  await testWatchdog();
  await testWatchReset();
  await testMutePersisted();
  await testMediaTransport();
  await testWatchPlay();
  await testReseedKeepsScrollback();
  await testReseedDedupes();
  await testReseedQuietWhenNothingNew();
  await testReseedRepeatedTurns();
  await testReseedEmptyPage();
  console.log("");
  console.log(PASS + " passed, " + FAIL + " failed");
  process.exit(FAIL === 0 ? 0 : 1);
})();
