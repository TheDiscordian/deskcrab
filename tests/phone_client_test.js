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
    turnCtl: null, lastTurnProgress: 0, turnKicked: false, releasedSeq: 0,
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
    turnCtl: null, lastTurnProgress: 0, turnKicked: false, releasedSeq: 0,
    // Answers cleanly every time, forever: nothing ever throws, so a deadline
    // that is only read inside the catch is never read at all.
    fetch: async () => ({
      ok: true, status: 200,
      body: { getReader: () => ({ read: async () => ({ done: true }) }) },
    }),
  };
  const body = lift("async function streamTurn")
      .replace("6 * 60 * 1000", "150")       // a ceiling this test can reach
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
    turnCtl: null, lastTurnProgress: 0, turnKicked: false, releasedSeq: 0,
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
      .replace("6 * 60 * 1000", "500")    // the give-up, reachable in a test
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
    turnCtl: null, lastTurnProgress: 0, turnKicked: false, releasedSeq: 0,
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
      .replace("6 * 60 * 1000", "400")
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
      .replace("7 * 60 * 1000", "250")    // the stall ceiling
      .replace("5 * 1000", "50");         // the poll
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
    watchFilter: () => false,
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

// --- 5: recovery (spec rules 39-41) — the button can never stay grey --------
//
// Written against 2026-08-08: the hold-to-talk button sat grey until a hand
// reload, twice reported in one evening. The holes: transcription fetches
// with no bound at all, and a reload mid-turn orphaning the turn behind the
// lock so the re-asked question showed nothing either.

// Enough of the page to run runTurn: the button, the bubbles, the spies.
function turnCtx(streamImpl) {
  const cls = new Set();
  const statuses = [];
  const remembered = [];
  let forgotten = 0;
  return {
    busy: false, turnSeq: 0, lastTurnProgress: 0, voiceMuted: false,
    pendingUser: null, pendingReply: null,
    awaitedUserSeen: false, liveTurn: null, releasedSeq: 0,
    sttSid: null, sttChain: Promise.resolve(), sttFailed: false,
    talk: { classList: { add: c => cls.add(c), remove: c => cls.delete(c),
                         contains: c => cls.has(c) } },
    setStatus: (s) => statuses.push(s),
    addTurn: () => ({ you: { textContent: "", scrollIntoView() {} },
                      reply: { textContent: "", scrollIntoView() {} } }),
    armTurnWatchdog: () => () => {},
    randomHex: () => "feedfacefeedfacefeedfacefeedface",
    rememberTurn: (tid, text) => remembered.push({ tid, text }),
    forgetTurn: () => { forgotten++; },
    norm: s => (s || "").replace(/\s+/g, " ").trim(),
    foldThoughts: () => {},
    deliver: async () => {},
    updateTalkBtn: () => {},
    post: async () => ({ transcript: "hi" }),
    streamTurn: streamImpl,
    _cls: cls, _statuses: statuses, _remembered: remembered,
    _forgotten: () => forgotten,
  };
}

async function testTurnEndsHandBackButton() {
  console.log("");
  console.log("runTurn — however the turn ends, the button comes back:");

  // The turn ends in an error payload.
  let ctx = turnCtx(async () => ({ error: "it broke" }));
  await build(["async function runTurn"], ctx).runTurn(null, null, "hello");
  if (!ctx.busy && !ctx._cls.has("busy"))
    ok("an error completion hands the button back");
  else bad("busy must clear on an error completion",
           "busy=" + ctx.busy + " cls=" + [...ctx._cls]);

  // The turn path throws outright.
  ctx = turnCtx(async () => { throw new Error("boom"); });
  await build(["async function runTurn"], ctx).runTurn(null, null, "hello");
  if (!ctx.busy && !ctx._cls.has("busy"))
    ok("a thrown turn hands the button back");
  else bad("busy must clear when the turn path throws",
           "busy=" + ctx.busy + " cls=" + [...ctx._cls]);
  if (ctx._statuses.some(s => /boom/.test(s)))
    ok("and says what happened");
  else bad("the throw must reach the status line", ctx._statuses.join(" | "));

  // The memory of the turn: written before the stream, wiped when it ends.
  ctx = turnCtx(async () => ({ spoken: "fine" }));
  await build(["async function runTurn"], ctx).runTurn(null, null, "hello");
  if (ctx._remembered.length === 1 && ctx._remembered[0].text === "hello")
    ok("the in-flight turn is remembered for a reload to find");
  else bad("rememberTurn must run before the stream",
           JSON.stringify(ctx._remembered));
  if (ctx._forgotten() >= 1)
    ok("and forgotten the moment the turn ends");
  else bad("forgetTurn must run when the turn ends", ctx._forgotten());
}

async function testHungTranscriptionIsBounded() {
  console.log("");
  console.log("runTurn — a transcription fetch that hangs cannot hold the button (rule 40):");
  // The real post() with a fetch that never settles on its own: only post's
  // abort guard ends it. The chain never settles either. Bounds shrunk to
  // what a test can wait for.
  const ctx = turnCtx(async () => ({ spoken: "never reached" }));
  ctx.sttSid = "abc";
  ctx.sttChain = new Promise(() => {});             // a slice upload, stuck
  // The REAL post must be the one resolved, not the harness stub: under
  // `with`, a ctx property shadows the lifted declaration.
  delete ctx.post;
  ctx.fetch = (url, opts) => new Promise((res, rej) => {
    opts.signal.addEventListener("abort", () => rej(new Error("aborted")));
  });
  const body = lift("function post") + "\n" +
      lift("async function runTurn")
          .replace("8000", "120")     // the chain-settle race
          .replace("30000", "180")    // the finish bound
          .replace("75000", "250");   // the batch fallback bound
  const api = new Function("ctx", "with (ctx) {\n" + body +
                           "\nreturn {runTurn};\n}")(ctx);
  const started = Date.now();
  await Promise.race([
    api.runTurn(new Uint8Array(2000), "audio/webm", null),
    sleep(4000).then(() => { throw new Error("HARNESS TIMEOUT"); }),
  ]).catch(e => bad("runTurn must return on its own", e.message));
  const took = Date.now() - started;
  if (!ctx.busy && !ctx._cls.has("busy"))
    ok("the hung fetch was aborted and the button handed back (" + took + "ms)");
  else bad("an unbounded transcription fetch is the grey button",
           "busy=" + ctx.busy);
  if (took < 2000) ok("inside the bound, not the watchdog");
  else bad("recovery must come from the fetch bound", took + "ms");
}

async function testResumePending() {
  console.log("");
  console.log("resumePending — a reload mid-turn re-attaches, never re-asks blind (rule 39):");
  function rctx(stored, seedTurns) {
    const calls = [];
    const store = { v: stored ? JSON.stringify(stored) : null };
    return {
      RESUME_MAX_AGE_MS: 10 * 60 * 1000,
      localStorage: { getItem: () => store.v,
                      removeItem: () => { store.v = null; },
                      setItem: (k, v) => { store.v = v; } },
      norm: s => (s || "").replace(/\s+/g, " ").trim(),
      runTurn: (b, c, text, tid, at) => calls.push({ text, tid, at }),
      _calls: calls, _store: store, _seed: { turns: seedTurns || [] },
    };
  }
  const lifted = ["function forgetTurn", "function resumePending"];

  // A fresh memory whose exchange is NOT on the seed: re-attach.
  const postedAt = Date.now() - 30000;
  let ctx = rctx({ tid: "cafe01", text: "how did it go", at: postedAt });
  build(lifted, ctx).resumePending(ctx._seed);
  if (ctx._calls.length === 1 && ctx._calls[0].tid === "cafe01"
      && ctx._calls[0].text === "how did it go")
    ok("the remembered turn is re-joined with the SAME identifier");
  else bad("a fresh in-flight memory must re-attach", JSON.stringify(ctx._calls));
  if (ctx._calls.length === 1 && ctx._calls[0].at === postedAt)
    ok("and it carries the ORIGINAL clock, not a fresh stamp");
  else bad("a resume must carry the original post's clock (rule 39)",
           JSON.stringify(ctx._calls));

  // The seed already carries the exchange: nothing to do, memory wiped.
  ctx = rctx({ tid: "cafe02", text: "how did it go", at: Date.now() - 30000 },
             [{ role: "user", text: "how did it go" },
              { role: "assistant", text: "fine, in fact" }]);
  build(lifted, ctx).resumePending(ctx._seed);
  if (ctx._calls.length === 0 && ctx._store.v === null)
    ok("a turn the seed already shows is not re-drawn or re-run");
  else bad("an answered turn must not resume",
           JSON.stringify(ctx._calls) + " store=" + ctx._store.v);

  // A memory past the age bound: wiped, never posted — rule 1 would CREATE.
  ctx = rctx({ tid: "cafe03", text: "good night", at: Date.now() - 11 * 60 * 1000 });
  build(lifted, ctx).resumePending(ctx._seed);
  if (ctx._calls.length === 0 && ctx._store.v === null)
    ok("an aged-out memory is dropped — re-posting it could start a turn");
  else bad("the age bound must hold", JSON.stringify(ctx._calls));
}

async function testResumeKeepsOriginalClock() {
  console.log("");
  console.log("rememberTurn — a resume keeps the clock it was posted with (rule 39):");
  const store = { v: null };
  const ctx = {
    localStorage: { setItem: (k, v) => { store.v = v; },
                    getItem: () => store.v,
                    removeItem: () => { store.v = null; } },
  };
  const api = build(["function rememberTurn"], ctx);

  api.rememberTurn("cafe10", "how goes it", 123456789);
  let rec = JSON.parse(store.v);
  if (rec.at === 123456789)
    ok("a resumed turn is re-remembered with the original stamp");
  else bad("restamping is how a reload storm resumed a dead turn forever", store.v);

  const before = Date.now();
  api.rememberTurn("cafe11", "how goes it");
  rec = JSON.parse(store.v);
  if (rec.at >= before) ok("a fresh turn is stamped now, as ever");
  else bad("a fresh turn must stamp the present", store.v);
}

async function testQueueWaitLine() {
  console.log("");
  console.log("showThought — a queued turn's wait notes draw ONE line, in place (rule 43):");
  const statuses = [];
  const mk = tag => ({
    tag, className: "", textContent: "", children: [],
    classList: { contains: () => false, toggle: () => {}, add: () => {} },
    append(...n) { this.children.push(...n); },
    scrollIntoView() {},
  });
  const parent = mk("div");
  parent.insertBefore = (n, ref) => {
    const i = parent.children.indexOf(ref);
    parent.children.splice(i < 0 ? parent.children.length : i, 0, n);
  };
  const reply = mk("div");
  reply.parentNode = parent;
  parent.children.push(reply);
  const turn = { reply };
  const ctx = {
    document: { createElement: mk },
    setStatus: s => statuses.push(s),
    addSaid: () => {},
  };
  const api = build(["function headText", "function showThought"], ctx);

  api.showThought(turn, { kind: "wait", text: "in line — she's in the middle of something else" });
  api.showThought(turn, { kind: "wait", text: "in line — she's in the middle of something else (1 min so far)" });

  const rows = turn.thoughts ? turn.thoughts.children : [];
  if (rows.length === 1) ok("two wait notes draw one line, not a pile");
  else bad("wait notes must update in place", rows.length + " rows");
  if (rows[0] && rows[0].textContent.indexOf("1 min so far") >= 0)
    ok("and the line carries the latest note");
  else bad("the line must carry the latest note", rows[0] && rows[0].textContent);
  if (statuses[statuses.length - 1] &&
      statuses[statuses.length - 1].indexOf("in line") === 0)
    ok("the status line says what the wait is, not a frozen resume message");
  else bad("the status must carry the wait note", statuses.join(" | "));

  api.showThought(turn, { kind: "thinking", text: "right, the calendar" });
  if (turn.thoughts.children.length === 2)
    ok("a real thought still lands as its own row after the wait");
  else bad("real thoughts must append as ever", turn.thoughts.children.length + " rows");
}

async function testResumeReplayIsQuiet() {
  console.log("");
  console.log("streamTurn — a re-attach replays quietly and speaks only what is live:");
  const enc = new TextEncoder();
  const posts = [];
  const voiced = [];
  let reads = 0;
  const ctx = {
    IDLE_MS: 60000,
    randomHex: () => "MUSTNOTBEUSED",
    setStatus: () => {},
    showThought: () => {},
    enqueueVoice: u => voiced.push(u),
    turnCtl: null, lastTurnProgress: 0, turnKicked: false, releasedSeq: 0,
    fetch: async (url, opts) => {
      posts.push({ url, body: opts && opts.body });
      return { ok: true, status: 200, body: { getReader: () => ({
        read: () => new Promise(res => {
          reads++;
          if (reads === 1)          // the buffered backlog, replayed at once
            res({ value: enc.encode(
                'data: {"kind":"voice","audio":"/audio/old.opus"}\n\n'),
                  done: false });
          else if (reads === 2)     // a clip that is genuinely live
            setTimeout(() => res({ value: enc.encode(
                'data: {"kind":"voice","audio":"/audio/new.opus"}\n\n' +
                'data: {"kind":"done","spoken":"back"}\n\n'), done: false }),
                350);
          else res({ done: true });
        }),
      }) } };
    },
  };
  const body = lift("async function streamTurn")
      .replace("1500", "200")            // the replay gate, test-reachable
      .replace(/STREAM_IDLE_MS/g, "IDLE_MS");
  const api = new Function("ctx", "with (ctx) {\n" + body +
                           "\nreturn {streamTurn};\n}")(ctx);
  const res = await Promise.race([
    api.streamTurn("hello", {}, "cafe1234", true),
    sleep(4000).then(() => ({ error: "HARNESS TIMEOUT" })),
  ]);
  if (res && res.spoken === "back") ok("the re-attached turn completes");
  else bad("the resume must ride the normal stream",
           (res && (res.error || JSON.stringify(res))) || "nothing");
  if (posts.length && /"turn":"cafe1234"/.test(posts[0].body || ""))
    ok("the POST carries the remembered id — an attach, never a second run");
  else bad("the given id must ride the POST", posts.length ? posts[0].body : "no post");
  if (voiced.join(",") === "/audio/new.opus")
    ok("the replayed backlog stays quiet; the live clip plays");
  else bad("replayed clips must not re-sound", voiced.join(",") || "nothing");
}

async function testForegroundKick() {
  console.log("");
  console.log("the foreground kick — coming back to a stale turn cuts it loose (rule 41):");
  let aborted = 0;
  const ctx = {
    busy: true,
    STREAM_IDLE_MS: 45000,
    lastTurnProgress: Date.now() - 60000,
    turnKicked: false,
    turnCtl: { abort: () => { aborted++; } },
  };
  build(["function kickStaleTurn"], ctx).kickStaleTurn();
  if (aborted === 1 && ctx.turnKicked)
    ok("a stale attempt is aborted, marked for an immediate reconnect");
  else bad("the kick must cut the stale attempt",
           "aborted=" + aborted + " kicked=" + ctx.turnKicked);

  const fresh = { busy: true, STREAM_IDLE_MS: 45000,
                  lastTurnProgress: Date.now(), turnKicked: false,
                  turnCtl: { abort: () => { aborted += 100; } } };
  build(["function kickStaleTurn"], fresh).kickStaleTurn();
  const idle = { busy: false, STREAM_IDLE_MS: 45000,
                 lastTurnProgress: 0, turnKicked: false,
                 turnCtl: { abort: () => { aborted += 100; } } };
  build(["function kickStaleTurn"], idle).kickStaleTurn();
  if (aborted === 1)
    ok("a working turn and an idle page are left alone");
  else bad("the kick must only fire on a stale busy turn", aborted);
}

async function testDeadMicReacquired() {
  console.log("");
  console.log("startRec — a microphone that died while the page was away is retaken (rule 41):");
  let acquired = 0, stopped = 0;
  const dead = { getTracks: () => [{ readyState: "ended",
                                     stop: () => { stopped++; } }] };
  const ctx = {
    busy: false, recWanted: false, stream: dead,
    navigator: { mediaDevices: { getUserMedia: async () => {
      acquired++;
      return { getTracks: () => [{ readyState: "live", stop() {} }] };
    } } },
    setStatus: () => {}, chunks: [], recorder: null,
    sttSid: null, sttChain: null, sttFailed: false,
    randomHex: () => "aabbccddeeff00112233445566778899",
    post: async () => ({}),
    MediaRecorder: class { constructor(s) { this.stream = s;
                                            this.mimeType = "audio/webm"; }
                           start() {} },
    talk: { classList: { add() {}, remove() {} }, textContent: "" },
  };
  await build(["async function startRec"], ctx).startRec();
  if (stopped === 1 && acquired === 1 && ctx.stream !== dead)
    ok("the dead stream is dropped and a fresh microphone taken");
  else bad("a dead cached stream must be replaced, not recorded from",
           "stopped=" + stopped + " acquired=" + acquired);
}

// --- 6: rule 42 — a reply arriving through the watcher ends the turn --------
//
// Written against 2026-08-08 23:42: the mirror rewrote the draft after its raw
// text streamed, so the stored reply no longer matched the own-turn filter and
// drew "at the laptop"; compaction — a whole model run — then sat between the
// conversation append and the exit that emits the done event. The stream
// carried nothing but pings, the answer sat on screen, and the button stayed
// grey until a hand reload at 23:43:29.

async function testWatcherReleasesTurn() {
  console.log("");
  console.log("rule 42 — the exchange arriving through the watcher hands the button back:");
  const enc = new TextEncoder();
  const cls = new Set();
  const statuses = [];
  const displays = [];
  let forgotten = 0, delivered = 0;
  const clips = [];
  const bubble = {
    textContent: "…",
    scrollIntoView() {},
    parentNode: { querySelector: () => null, append() {} },
  };
  const ctx = {
    busy: false, turnSeq: 0, lastTurnProgress: 0, voiceMuted: false,
    pendingUser: null, pendingReply: null,
    awaitedUserSeen: false, liveTurn: null, releasedSeq: 0,
    turnCtl: null, turnKicked: false, turnVoiced: false, STREAM_IDLE_MS: 60000,
    talk: { classList: { add: c => cls.add(c), remove: c => cls.delete(c),
                         contains: c => cls.has(c) } },
    setStatus: s => statuses.push(s),
    addTurn: () => ({ you: { textContent: "", scrollIntoView() {} },
                      reply: bubble }),
    armTurnWatchdog: () => () => {},
    randomHex: () => "feedfacefeedfacefeedfacefeedface",
    rememberTurn: () => {},
    forgetTurn: () => { forgotten++; },
    foldThoughts: () => {},
    deliver: async () => { delivered++; },
    updateTalkBtn: () => {},
    showThought: () => {},
    enqueueVoice: a => clips.push(a),
    attachDisplay: (el, html) => displays.push(html),
    // The C13 stream: opens fine, pings while the record already carries the
    // answer, and only much later — after compaction — emits its done event.
    // That event carries the turn's own reply clip, the only sound this turn
    // will ever make, which is why the release must not cut this socket.
    fetch: async (url, opts) => ({
      ok: true, status: 200, body: { getReader: () => ({
        read: () => new Promise((res, rej) => {
          const late = Date.now() - opened > 400;
          const frame = late
            ? "data: " + JSON.stringify({ kind: "done", spoken: "it went well, in fact",
                                          display_html: "", audio: "/audio/tail.wav",
                                          error: "" }) + "\n\n"
            : ": ping\n\n";
          const t = setTimeout(() => res(
            { value: enc.encode(frame), done: false }), 25);
          if (opts && opts.signal) opts.signal.addEventListener("abort",
            () => { clearTimeout(t); rej(new Error("aborted")); });
        }),
      }) },
    }),
  };
  const opened = Date.now();
  const api = build(["function norm", "async function streamTurn",
                     "function releaseTurn", "function watchFilter",
                     "async function runTurn"], ctx);
  const started = Date.now();
  const p = api.runTurn(null, null, "how did it go");
  await sleep(120);
  if (ctx.busy && cls.has("busy")) ok("the harness holds a live grey turn to release");
  else bad("the turn must be in flight before the watcher answers",
           "busy=" + ctx.busy);

  // The watcher poll delivers the exchange — the reply worded by the mirror,
  // not as it streamed (nothing streamed here at all).
  const hidUser = api.watchFilter({ role: "user", text: "how did it go" });
  const hidReply = api.watchFilter({ role: "assistant",
                                     text: "it went well, in fact",
                                     display_html: "<p>card</p>" });
  // The button comes back on the release, not on the stream: measured as soon
  // as busy clears, while the socket is still open for the voice.
  let took = 0;
  for (let i = 0; i < 60 && ctx.busy; i++) await sleep(25);
  took = Date.now() - started;
  await Promise.race([p, sleep(3000).then(() => {
    throw new Error("HARNESS TIMEOUT");
  })]).catch(e => bad("the voice tail must end when its done event lands", e.message));

  if (hidUser && hidReply) ok("both halves of the exchange are recognised, neither drawn twice");
  else bad("the own exchange must be suppressed", "user=" + hidUser + " reply=" + hidReply);
  if (!ctx.busy && !cls.has("busy"))
    ok("the button is handed back (" + took + "ms — well inside the watchdog)");
  else bad("busy must clear when the watcher delivers the reply",
           "busy=" + ctx.busy + " cls=" + [...cls]);
  if (took < 2000) ok("released by the watcher, not by any deadline");
  else bad("the release must be immediate", took + "ms");
  if (bubble.textContent === "it went well, in fact")
    ok("nothing streamed, so the record's text fills the live bubble");
  else bad("an empty bubble must take the watcher's reply", bubble.textContent);
  if (displays.length === 1) ok("and the display card rides in — it never streams");
  else bad("the display card must be attached on release", displays.length);
  if (forgotten >= 1) ok("the remembered turn is forgotten");
  else bad("forgetTurn must run on release", forgotten);
  if (delivered === 0) ok("deliver never runs — the record already settled the bubble");
  else bad("a released turn must not also deliver", delivered);
  if (clips.join(",") === "/audio/tail.wav")
    ok("but the completion clip still sounds — a reply read is a reply heard");
  else bad("the voice tail must play the clip the stream still owed",
           clips.join(",") || "silence");
  if (statuses.some(s => /arrived through the conversation/.test(s)))
    ok("and the status says what happened");
  else bad("the release must be announced", statuses.join(" | ") || "no status");
}

// The C14 shape, measured live 2026-08-09 16:54–16:55: sentence streaming cuts
// a clip per sentence, so the conversation append — which runs ahead of the
// synthesiser — arrived while the tail sentences were still becoming clips.
// The release saw a turn that had already sounded and cut the socket, and every
// clip past the second was synthesised, emitted, and never fetched: three
// replies in a row heard to stop mid-thought. The release must leave the
// stream open as a voice tail in EVERY case, not only the silent one.
async function testReleasedTailKeepsPlaying() {
  console.log("");
  console.log("rule 42 — a released turn's stream still delivers the clips it owes (C14):");
  const enc = new TextEncoder();
  const cls = new Set();
  const clips = [];
  let delivered = 0, aborted = 0, frame_n = 0;
  const bubble = {
    textContent: "…",
    scrollIntoView() {},
    parentNode: { querySelector: () => null, append() {} },
  };
  const ctx = {
    busy: false, turnSeq: 0, lastTurnProgress: 0, voiceMuted: false,
    pendingUser: null, pendingReply: null,
    awaitedUserSeen: false, liveTurn: null, releasedSeq: 0,
    turnCtl: null, turnKicked: false, turnVoiced: false, STREAM_IDLE_MS: 60000,
    talk: { classList: { add: c => cls.add(c), remove: c => cls.delete(c),
                         contains: c => cls.has(c) } },
    setStatus: () => {},
    addTurn: () => ({ you: { textContent: "", scrollIntoView() {} },
                      reply: bubble }),
    armTurnWatchdog: () => () => {},
    randomHex: () => "c14c14c14c14c14c14c14c14c14c14c1",
    rememberTurn: () => {},
    forgetTurn: () => {},
    foldThoughts: () => {},
    deliver: async () => { delivered++; },
    updateTalkBtn: () => {},
    showThought: () => {},
    enqueueVoice: a => clips.push(a),
    attachDisplay: () => {},
    // The incident's stream: the first clip lands at once, the tail clips only
    // after the record has already released the turn — they were still being
    // synthesised when the append reached the watcher.
    fetch: async (url, opts) => ({
      ok: true, status: 200, body: { getReader: () => ({
        read: () => new Promise((res, rej) => {
          const late = Date.now() - opened > 500;
          let frame = ": ping\n\n";
          if (frame_n === 0)
            frame = "data: " + JSON.stringify({ kind: "voice", text: "Hmph.",
                                                audio: "/audio/one.opus" }) + "\n\n";
          else if (late && frame_n === 1)
            frame = "data: " + JSON.stringify({ kind: "voice", text: "the tail",
                                                audio: "/audio/two.opus" }) + "\n\n";
          else if (late && frame_n === 2)
            frame = "data: " + JSON.stringify({ kind: "done", spoken: "Hmph. the tail",
                                                display_html: "", audio: "",
                                                error: "" }) + "\n\n";
          if (frame.startsWith("data:")) frame_n++;
          const t = setTimeout(() => res(
            { value: enc.encode(frame), done: false }), 25);
          if (opts && opts.signal) opts.signal.addEventListener("abort",
            () => { aborted++; clearTimeout(t); rej(new Error("aborted")); });
        }),
      }) },
    }),
  };
  const opened = Date.now();
  const api = build(["function norm", "async function streamTurn",
                     "function releaseTurn", "function watchFilter",
                     "async function runTurn"], ctx);
  const p = api.runTurn(null, null, "go on then");
  for (let i = 0; i < 40 && !clips.length; i++) await sleep(25);
  if (clips.length === 1) ok("the first clip has sounded while the turn runs");
  else bad("the harness must voice a clip before the release", clips.join(","));

  // The record arrives through the watcher with the tail clips still uncut.
  api.watchFilter({ role: "user", text: "go on then" });
  api.watchFilter({ role: "assistant", text: "Hmph. the tail, reworded" });
  if (!ctx.busy) ok("the watcher released the turn");
  else bad("the release must clear busy", ctx.busy);

  await Promise.race([p, sleep(3000).then(() => {
    throw new Error("HARNESS TIMEOUT");
  })]).catch(e => bad("the voice tail must end at its done event", e.message));

  if (aborted === 0) ok("the stream was left open — a voiced turn is not a finished one");
  else bad("the release must not cut the socket the tail clips ride", "aborted " + aborted);
  if (clips.join(",") === "/audio/one.opus,/audio/two.opus")
    ok("the clip cut after the release still plays — nothing swallowed");
  else bad("every clip the stream still owed must be enqueued",
           clips.join(",") || "silence");
  if (delivered === 0) ok("deliver never runs — the record already settled the bubble");
  else bad("a released turn must not also deliver", delivered);
}

async function testWatchFilterIdentity() {
  console.log("");
  console.log("rule 42 — only this turn's own answer can release it:");
  function fctx() {
    const releases = [];
    return {
      busy: true, turnSeq: 3,
      pendingUser: null, pendingReply: null, awaitedUserSeen: false,
      norm: s => (s || "").replace(/\s+/g, " ").trim(),
      releaseTurn: t => releases.push(t.text),
      _releases: releases,
    };
  }

  // A wake lands between the question and the answer: skipped, never a
  // candidate, and the wait survives it.
  let ctx = fctx(); ctx.pendingUser = "how goes it";
  let api = build(["function watchFilter"], ctx);
  api.watchFilter({ role: "user", text: "how goes it" });
  const drewWake = !api.watchFilter({ role: "assistant", text: "a wake speaks",
                                      mark: "autonomous wake" });
  api.watchFilter({ role: "assistant", text: "the real answer, reworded" });
  if (drewWake && ctx._releases.join(",") === "the real answer, reworded")
    ok("a marked block draws as ever and the reworded reply still releases");
  else bad("the mark must shield the wake and keep the wait alive",
           "drewWake=" + drewWake + " releases=" + ctx._releases.join(","));

  // Another voice's User block breaks the adjacency: whatever follows answers
  // it, not this turn.
  ctx = fctx(); ctx.pendingUser = "q one";
  api = build(["function watchFilter"], ctx);
  api.watchFilter({ role: "user", text: "q one" });
  api.watchFilter({ role: "user", text: "another voice" });
  const drew = !api.watchFilter({ role: "assistant", text: "its answer" });
  if (drew && ctx._releases.length === 0)
    ok("an intervening User block keeps another exchange's reply from releasing");
  else bad("adjacency must break on a foreign User block",
           "drew=" + drew + " releases=" + ctx._releases.length);

  // The exact-text match releases on its own, question echo or not.
  ctx = fctx(); ctx.pendingReply = "the words that streamed";
  api = build(["function watchFilter"], ctx);
  const hid = api.watchFilter({ role: "assistant", text: "the words that streamed" });
  if (hid && ctx._releases.length === 1 && ctx.pendingReply === null)
    ok("the reply matching what streamed releases and is not drawn twice");
  else bad("a pendingReply match while busy must release",
           "hid=" + hid + " releases=" + ctx._releases.length);

  // An idle page: a late answer to a given-up turn must stay visible.
  ctx = fctx(); ctx.busy = false; ctx.awaitedUserSeen = true;
  api = build(["function watchFilter"], ctx);
  const drewLate = !api.watchFilter({ role: "assistant", text: "a late answer" });
  if (drewLate && ctx._releases.length === 0)
    ok("an idle page draws the late reply instead of eating it");
  else bad("no release and no suppression while idle",
           "drew=" + drewLate + " releases=" + ctx._releases.length);
}

async function testReleaseGuards() {
  console.log("");
  console.log("rule 42 — the release cannot touch a turn it does not own:");
  let aborted = 0, forgotten = 0;
  const streamed = {
    textContent: "what streamed", _said: ["what streamed"],
    scrollIntoView() {},
    parentNode: { querySelector: () => null, append() {} },
  };
  const ctx = {
    busy: false, turnSeq: 7, releasedSeq: 0,
    liveTurn: { reply: streamed },
    turnCtl: { abort: () => { aborted++; } },
    forgetTurn: () => { forgotten++; },
    pendingReply: "x",
    talk: { classList: { remove() {} } },
    updateTalkBtn: () => {}, setStatus: () => {},
    attachDisplay: () => {}, foldThoughts: () => {},
  };
  const api = build(["function releaseTurn"], ctx);
  api.releaseTurn({ text: "too late" });
  if (aborted === 0 && forgotten === 0 && ctx.releasedSeq === 0)
    ok("an idle page is left exactly as it was");
  else bad("releaseTurn must refuse when no turn is in flight",
           "aborted=" + aborted + " forgotten=" + forgotten);

  ctx.busy = true;
  api.releaseTurn({ text: "the record's wording" });
  if (streamed.textContent === "what streamed")
    ok("a bubble that streamed keeps its words — no overwrite mid-read");
  else bad("streamed text must not be replaced", streamed.textContent);
  if (ctx.releasedSeq === 7 && aborted === 0 && !ctx.busy)
    ok("the release marks this turn's sequence and clears busy, stream untouched");
  else bad("the release must be guarded by the turn sequence",
           "seq=" + ctx.releasedSeq + " aborted=" + aborted + " busy=" + ctx.busy);

  // Whatever has or has not sounded, the stream survives the release: the
  // sound still owed — tail clips mid-synthesis, or a completion clip for a
  // turn that voiced nothing — can only arrive down it (C14).
  ctx.busy = true; ctx.turnSeq = 8;
  api.releaseTurn({ text: "silent so far" });
  if (aborted === 0 && !ctx.busy && ctx.releasedSeq === 8)
    ok("the stream is never cut by a release — the button comes back anyway");
  else bad("a released turn's stream must survive the release",
           "aborted=" + aborted + " busy=" + ctx.busy);
}

async function testResetPayloadReleases() {
  console.log("");
  console.log("/watch — the reply riding a busy reset's payload is scanned, not lost:");
  const seen = [];
  const ctx = {
    watching: false, needReseed: false, busy: true,
    cursor: 5, gen: "STALE", wakeSeen: "", playSeen: "", voiceMuted: false,
    reseed: async () => {},
    renderRemote: () => {},
    enqueueVoice: () => {},
    watchFilter: t => { seen.push(t.role + ":" + t.text); return true; },
    fetch: async () => {
      await sleep(20);
      if (ctx.gen !== "FRESH")
        return { ok: true, json: async () => (
          { n: 2, gen: "FRESH", reset: true,
            turns: [{ role: "user", text: "the question" },
                    { role: "assistant", text: "the answer" }] }) };
      return { ok: true, json: async () => ({ n: 2, gen: "FRESH", turns: [] }) };
    },
  };
  build(["async function startWatch"], ctx).startWatch();
  await sleep(400);
  if (seen.join(" | ") === "user:the question | assistant:the answer")
    ok("every block in the reset payload passes the own-turn filter");
  else bad("the reset payload must be scanned for this turn's reply",
           seen.join(" | ") || "nothing scanned");
  if (ctx.needReseed) ok("and the redraw still waits for the turn to end");
  else bad("the deferral must survive the scan", "needReseed=" + ctx.needReseed);
}

(async () => {
  await testStreamTurn();
  await testDeadline();
  await testPingsAreNotProgress();
  await testProgressExtendsDeadline();
  await testWatchdog();
  await testTurnEndsHandBackButton();
  await testHungTranscriptionIsBounded();
  await testResumePending();
  await testResumeKeepsOriginalClock();
  await testQueueWaitLine();
  await testResumeReplayIsQuiet();
  await testForegroundKick();
  await testDeadMicReacquired();
  await testWatcherReleasesTurn();
  await testReleasedTailKeepsPlaying();
  await testWatchFilterIdentity();
  await testReleaseGuards();
  await testResetPayloadReleases();
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
