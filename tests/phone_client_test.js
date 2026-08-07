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

(async () => {
  await testStreamTurn();
  await testDeadline();
  await testWatchReset();
  console.log("");
  console.log(PASS + " passed, " + FAIL + " failed");
  process.exit(FAIL === 0 ? 0 : 1);
})();
