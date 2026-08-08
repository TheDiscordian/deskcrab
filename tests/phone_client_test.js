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
  if (res && /gave up reconnecting/.test(res.error || ""))
    ok("a turn that is alive but going nowhere ends at the ceiling");
  else
    bad("the deadline must be checked on the loop, not only after a throw",
        (res && (res.error || JSON.stringify(res))) || "never returned");
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
  await testWatchReset();
  await testReseedKeepsScrollback();
  await testReseedDedupes();
  await testReseedQuietWhenNothingNew();
  await testReseedRepeatedTurns();
  await testReseedEmptyPage();
  console.log("");
  console.log(PASS + " passed, " + FAIL + " failed");
  process.exit(FAIL === 0 ? 0 : 1);
})();
