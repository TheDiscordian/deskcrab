// The client half of specs/phone.md rules 5 and 49 as amended 2026-08-11, and
// the queue feeding rule 51's mid-turn spool: hold-to-talk is never refused
// while a turn runs, a mid-turn recording transcribes and queues exactly as a
// typed send does, and the page's own playback is paused while the microphone
// is open. Run through tests/test_phone_client.sh beside phone_client_test.js.
//
// Same extraction discipline as phone_client_test.js: the page has no module
// boundary, so functions are lifted by name and evaluated with every free
// name supplied — a rename fails loudly rather than silently testing nothing.

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

function build(names, ctx) {
  const body = names.map(lift).join("\n");
  const exports = names.map(n => n.replace(/^(async )?function /, "").replace(/\(.*/, ""))
                       .filter(n => /^[A-Za-z_$][\w$]*$/.test(n));
  return new Function("ctx", "with (ctx) {\n" + body +
                      "\nreturn {" + exports.join(",") + "};\n}")(ctx);
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

const classListStub = () => {
  const set = new Set();
  return { add: c => set.add(c), remove: c => set.delete(c),
           toggle: () => {}, contains: c => set.has(c) };
};

// --- 1: the microphone is never refused, and playback ducks under it -------

async function testRecordWhileBusy() {
  console.log("startRec while busy — recorded and queued, never refused:");

  class FakeRecorder {
    constructor() { this.state = "inactive"; }
    start() { this.state = "recording"; }
    stop() { this.state = "inactive"; if (this.onstop) this.onstop(); }
  }
  const queued = [], ran = [];
  let status = "";
  const player = { paused: false, src: "clip",
                   pause() { this.paused = true; },
                   play() { this.paused = false; return Promise.resolve(); } };
  const music = { paused: true, ended: false, src: "" };
  const ctx = {
    busy: true, recWanted: false, recorder: null, chunks: [], stream: null,
    sttSid: null, sttChain: Promise.resolve(), sttFailed: false,
    voicePlaying: true, playerMeta: { tid: "t" }, player, music,
    duckedVoice: false, duckedMusic: false,
    talk: Object.assign({ textContent: "" }, { classList: classListStub() }),
    navigator: { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) } },
    MediaRecorder: FakeRecorder,
    Blob,
    randomHex: n => "ab".repeat(n / 2),
    setStatus: s => { status = s; },
    post: async () => ({}),
    updateTalkBtn: () => {},
    queueRecorded: (blob, ctype, take) => { queued.push({ blob, ctype, take }); },
    runTurn: (...a) => { ran.push(a); },
  };
  const page = build(["async function startRec", "function stopRec",
                      "function duckPlayback", "function unduckPlayback"], ctx);

  await page.startRec();
  if (ctx.recorder && ctx.recorder.state === "recording")
    ok("recording started with a turn in flight — the old busy refusal is gone");
  else
    bad("recording must start while busy", ctx.recorder && ctx.recorder.state);
  if (status === "listening…") ok("and the page says it is listening");
  else bad("status should be listening", status);
  if (player.paused) ok("the playing voice clip was paused the moment the mic opened");
  else bad("playback must duck under the microphone", "still playing");

  // Two seconds of audio arrive, then the finger lifts.
  ctx.recorder.ondataavailable({ data: new Blob(["x".repeat(2000)]) });
  await sleep(10);
  page.stopRec();
  await sleep(10);
  if (queued.length === 1 && ran.length === 0)
    ok("the take was routed to the queue, not run over the live turn");
  else
    bad("a busy release must queue", "queued " + queued.length + ", ran " + ran.length);
  if (queued[0] && queued[0].take && "sid" in queued[0].take)
    ok("with its own stt session captured at release");
  else
    bad("the take must carry its stt session", JSON.stringify(queued[0] && queued[0].take));
  if (!player.paused) ok("and the paused clip resumed when the mic closed");
  else bad("release must resume the ducked playback", "still paused");
}

// --- 2: the mid-turn take joins the queue and is posted at once ------------

async function testQueueRecorded() {
  console.log("queueRecorded — transcribed, drawn, queued, and posted at once:");

  const seeded = [], pumped = [];
  let status = "", bubble = null;
  const ctx = {
    addTurn: you => {
      bubble = { you: { textContent: you },
                 reply: { textContent: "", classList: classListStub(),
                          parentNode: { remove: () => {} } } };
      return bubble;
    },
    transcribeBlob: async () => ({ transcript: "the mid-turn words" }),
    norm: s => (s || "").trim(),
    randomHex: () => "feedbead",
    sendQueue: [],
    seedTurn: (text, tid) => seeded.push({ text, tid }),
    setStatus: s => { status = s; },
    pumpQueue: () => pumped.push(1),
    Date,
  };
  const page = build(["async function queueRecorded"], ctx);

  await page.queueRecorded({}, "audio/webm", {});
  if (ctx.sendQueue.length === 1 && ctx.sendQueue[0].text === "the mid-turn words")
    ok("the transcript joined the send queue");
  else
    bad("the transcript must join the queue", JSON.stringify(ctx.sendQueue));
  if (seeded.length === 1 && seeded[0].text === "the mid-turn words"
      && seeded[0].tid === ctx.sendQueue[0].tid)
    ok("and was posted to the laptop at once, under the id the attach will re-use");
  else
    bad("the message must be seeded to the server immediately", JSON.stringify(seeded));
  if (bubble && bubble.you.textContent === "the mid-turn words")
    ok("the bubble shows what was heard");
  else
    bad("the bubble must carry the transcript", bubble && bubble.you.textContent);
  if (pumped.length === 1)
    ok("the queue is pumped after transcription — a take never waits for a next turn");
  else
    bad("queueRecorded must pump the queue", pumped.length);
  if (/queued/.test(status)) ok("and the status says queued with the stop control named");
  else bad("status should say queued", status);
}

// --- 3: a transcription failure says so instead of dying silently ----------

async function testQueueRecordedFailure() {
  console.log("queueRecorded — a failed transcription is shown, not swallowed:");

  const seeded = [];
  let bubble = null;
  const ctx = {
    addTurn: you => {
      bubble = { you: { textContent: you },
                 reply: { textContent: "", classList: classListStub(),
                          parentNode: { remove: () => {} } } };
      return bubble;
    },
    transcribeBlob: async () => ({ error: "stream lost" }),
    norm: s => (s || "").trim(),
    randomHex: () => "feedbead",
    sendQueue: [],
    seedTurn: (text, tid) => seeded.push({ text, tid }),
    setStatus: () => {},
    pumpQueue: () => {},
    Date,
  };
  const page = build(["async function queueRecorded"], ctx);

  await page.queueRecorded({}, "audio/webm", {});
  if (ctx.sendQueue.length === 0 && seeded.length === 0)
    ok("nothing was queued or posted for a take that produced no words");
  else
    bad("a failed take must not queue", JSON.stringify({ q: ctx.sendQueue, s: seeded }));
  if (bubble && /stream lost/.test(bubble.reply.textContent))
    ok("and the failure is written into the take's own bubble");
  else
    bad("the bubble must name the failure", bubble && bubble.reply.textContent);
}

// --- 4: a take that lands on an idle page runs immediately -----------------

async function testQueuePumpsWhenIdle() {
  console.log("queueRecorded on a page gone idle — pumps into a real turn now:");

  const ran = [];
  const ctx = {
    busy: false,
    addTurn: you => ({ you: { textContent: you },
                       reply: { textContent: "", classList: classListStub(),
                                parentNode: { remove: () => {} } } }),
    transcribeBlob: async () => ({ transcript: "late words" }),
    norm: s => (s || "").trim(),
    randomHex: () => "feedbead",
    sendQueue: [],
    seedTurn: () => {},
    setStatus: () => {},
    runTurn: (...a) => ran.push(a),
    Date,
  };
  const page = build(["async function queueRecorded", "function pumpQueue"], ctx);

  await page.queueRecorded({}, "audio/webm", {});
  await sleep(10);
  if (ran.length === 1 && ran[0][2] === "late words")
    ok("the turn ended mid-transcription and the take still ran, immediately");
  else
    bad("an idle page must pump the fresh take into a turn", JSON.stringify(ran));
}

// --- 5: transcribeBlob still speaks both of its dialects -------------------

async function testTranscribePaths() {
  console.log("transcribeBlob — the streaming finish, and the whole-blob fallback:");

  const calls = [];
  const ctx = {
    sttSid: null, sttChain: Promise.resolve(), sttFailed: false,
    post: async (url) => {
      calls.push(url);
      if (url.startsWith("/stt/finish")) return { transcript: "finished" };
      return { transcript: "fallback" };
    },
  };
  const page = build(["async function transcribeBlob"], ctx);

  let t = await page.transcribeBlob({}, "audio/webm",
                                    { sid: "s1", chain: Promise.resolve() });
  if (t.transcript === "finished" && calls.some(u => u.startsWith("/stt/finish?s=s1")))
    ok("a surviving stt session is finished, not re-uploaded");
  else
    bad("the streaming finish must be used", JSON.stringify({ t, calls }));

  calls.length = 0;
  t = await page.transcribeBlob({}, "audio/webm",
                                { sid: null, chain: Promise.resolve() });
  if (t.transcript === "fallback" && calls.length === 1 && calls[0] === "/transcribe")
    ok("no session falls back to the whole recording");
  else
    bad("the fallback must send the blob", JSON.stringify({ t, calls }));
}

(async () => {
  await testRecordWhileBusy();
  await testQueueRecorded();
  await testQueueRecordedFailure();
  await testQueuePumpsWhenIdle();
  await testTranscribePaths();
  console.log("");
  console.log(PASS + " passed, " + FAIL + " failed");
  process.exit(FAIL === 0 ? 0 : 1);
})();
