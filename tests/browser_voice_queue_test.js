// The shared voice queue, bare (specs/phone.md rule 44c; specs/chessweb.md
// rule 24g): the mechanics BOTH pages ride, driven directly through require()
// with scripted policies — no page, no element, no server. What the pages
// prove through their own glue (tests/phone_client_deadclip_test.js,
// tests/chess_client_chat_test.js), this file proves is the module's to give:
// arrival-order serial playback exactly once; the terminal dead state and its
// enqueue-time skip; both orderings of a dead source's two signals collapsing
// to one failure; the refusal hold and its gesture resume; the never-started
// bound with its progress re-arm and duck deferral; ended-without-start
// reported as the failure it is; drop-queued sparing the clip already
// sounding; and the silent stop.
//
// Run: node tests/browser_voice_queue_test.js   (or through
//      tests/test_shared_voice_asset.sh)
'use strict';

const path = require('path');
const { createVoiceQueue } = require(
  path.join(__dirname, '..', 'lib', 'browser_voice_queue.js'));

let PASS = 0, FAIL = 0;
const ok = m => { PASS++; console.log('  ok: ' + m); };
const bad = (m, got) => {
  FAIL++;
  console.log('  FAIL: ' + m + ' — got [' + got + ']');
};
const sleep = ms => new Promise(r => setTimeout(r, ms));

// A queue over a scripted player: each item's key picks a script — how its
// "element" behaves once play() is called. The log records every policy call
// in order, which is the whole observable surface.
function rig(opts) {
  opts = opts || {};
  const log = [];
  const clips = {};          // key -> the live clip handle, for hand-driving
  const q = createVoiceQueue({
    startGraceMs: opts.startGraceMs || 120,
    refusalGraceMs: opts.refusalGraceMs || 40,
    isDucked: opts.isDucked,
    shouldPlay: opts.shouldPlay,
    deadKey: it => it.key,
    play: (it, clip) => {
      clips[it.key] = clip;
      log.push('play:' + it.key);
      const mode = (opts.script && opts.script[it.key]) || 'manual';
      if (mode === 'end') {
        setTimeout(() => { clip.playing(); clip.ended(); }, 10);
      } else if (mode === 'error') {
        setTimeout(() => clip.error('media error 4'), 10);
      }
      // 'manual': the test drives the handle itself.
    },
    unload: (it, outcome) => log.push('unload:' + it.key + ':' + outcome),
    onRequested: it => log.push('requested:' + it.key),
    onStarted: it => log.push('started:' + it.key),
    onCompleted: it => log.push('completed:' + it.key),
    onFailed: (it, why) => log.push('failed:' + it.key + ':' + why),
    onRefusal: opts.onRefusal,
    onDeadEnqueue: it => log.push('deadenq:' + it.key),
  });
  return { q, log, clips };
}

const only = (log, kind) => log.filter(l => l.startsWith(kind + ':'));

// --- 1: arrival order, one at a time, exactly once -------------------------

async function testOrderSerialOnce() {
  console.log('three clips: arrival order, serial, each exactly once:');
  const r = rig({ script: { a: 'end', b: 'end', c: 'end' } });
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  r.q.enqueue({ key: 'c' });
  await sleep(120);
  const plays = only(r.log, 'play').join(',');
  if (plays === 'play:a,play:b,play:c')
    ok('played in arrival order, each once');
  else bad('arrival order, exactly once', plays);
  // Serial: b's play must come after a's terminal outcome, never inside it.
  const ia = r.log.indexOf('completed:a'), ib = r.log.indexOf('play:b');
  if (ia >= 0 && ib > ia) ok('the next clip starts only after the last settles');
  else bad('serial playback', r.log.join(' | '));
  if (only(r.log, 'completed').length === 3 && only(r.log, 'failed').length === 0)
    ok('three completions, no failures invented');
  else bad('clean run must be three completions', r.log.join(' | '));
  if (!r.q.busy()) ok('the queue ends idle');
  else bad('busy() must clear', r.q.busy());
}

// --- 2: the terminal dead state and the enqueue-time skip -------------------

async function testDeadStateTerminal() {
  console.log('');
  console.log('a failed key is dead for good — skipped at the door:');
  const r = rig({ script: { a: 'error', b: 'end' } });
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  await sleep(80);
  if (only(r.log, 'failed').length === 1 && r.q.isDead('a'))
    ok('the failure marks the key dead');
  else bad('one failure, one dead mark', r.log.join(' | '));
  if (r.log.indexOf('play:b') >= 0 && only(r.log, 'completed').length === 1)
    ok('the queue advanced past it');
  else bad('a dead clip must not park the queue', r.log.join(' | '));
  r.q.enqueue({ key: 'a' });
  await sleep(40);
  if (only(r.log, 'play').length === 2 && only(r.log, 'deadenq').length === 1)
    ok('the dead key is never played again, and the skip is witnessed');
  else bad('a dead key must be skipped at enqueue', r.log.join(' | '));
}

// --- 3: rejection-first — the racing error event owns the clip --------------

async function testRejectionFirstRace() {
  console.log('');
  console.log('rejection first, error inside the grace: one failure, no refusal:');
  let refused = 0;
  const r = rig({ onRefusal: () => { refused++; return true; } });
  r.q.enqueue({ key: 'a' });
  await sleep(5);
  r.clips.a.rejected({ name: 'NotAllowedError' });   // the rejection lands FIRST
  await sleep(5);
  r.clips.a.error('media error 4');                  // …then the element's own event
  await sleep(100);                                  // past the refusal grace
  const fails = only(r.log, 'failed');
  if (fails.length === 1 && /media error 4/.test(fails[0]))
    ok('exactly one failure, and it is the media error');
  else bad('one media-error failure', r.log.join(' | '));
  if (refused === 0) ok('no refusal is invented for a source that failed to load');
  else bad('the refusal policy must not fire', refused);
}

// --- 3b: error-first — the trailing rejection is nothing --------------------

async function testErrorFirstRace() {
  console.log('');
  console.log('error first, rejection trailing: same single failure:');
  let refused = 0;
  const r = rig({ onRefusal: () => { refused++; return true; } });
  r.q.enqueue({ key: 'a' });
  await sleep(5);
  r.clips.a.error('media error 4');
  await sleep(5);
  r.clips.a.rejected({ name: 'NotAllowedError' });
  await sleep(100);
  if (only(r.log, 'failed').length === 1 && refused === 0)
    ok('one failure, no refusal, in this ordering too');
  else bad('error-first must end the same way',
           r.log.join(' | ') + ' refused=' + refused);
  if (only(r.log, 'unload').length === 1)
    ok('and the clip was unloaded exactly once');
  else bad('one terminal outcome, one unload', r.log.join(' | '));
}

// --- 3c: a non-refusal rejection is not acted on ----------------------------

async function testOtherRejectionIgnored() {
  console.log('');
  console.log('a NotSupportedError rejection is left to the error event or the bound:');
  let refused = 0;
  const r = rig({ onRefusal: () => { refused++; return true; } });
  r.q.enqueue({ key: 'a' });
  await sleep(5);
  r.clips.a.rejected({ name: 'NotSupportedError' });
  await sleep(60);                       // inside the start grace
  if (only(r.log, 'failed').length === 0 && refused === 0)
    ok('nothing is believed from the rejection alone');
  else bad('a non-refusal rejection must not settle the clip',
           r.log.join(' | '));
  await sleep(120);                      // now the bound fires
  if (only(r.log, 'failed').length === 1
      && /never started/.test(only(r.log, 'failed')[0]))
    ok('the never-started bound is the backstop');
  else bad('the bound must own a clip with no other signal', r.log.join(' | '));
}

// --- 4: the genuine refusal — held for a gesture, resumed by the element ----

async function testRefusalHoldAndResume() {
  console.log('');
  console.log('a genuine refusal held for the gesture: parked, never shot, resumed:');
  let refused = 0;
  const r = rig({ onRefusal: () => { refused++; return true; } });
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  await sleep(5);
  r.clips.a.rejected({ name: 'NotAllowedError' });
  await sleep(100);                      // past the refusal grace
  if (refused === 1) ok('the refusal policy fired once');
  else bad('one refusal', refused);
  if (only(r.log, 'play').length === 1 && r.q.busy())
    ok('the queue parks behind the held clip — advancing would only meet the same refusal');
  else bad('a held clip must park the queue', r.log.join(' | '));
  await sleep(200);                      // far past the start grace
  if (only(r.log, 'failed').length === 0)
    ok('a clip waiting on a tap is not stuck: the bound stands disarmed');
  else bad('the hold must disarm the give-up clock', r.log.join(' | '));
  r.clips.a.playing();                   // the tap: the element's own truth
  r.clips.a.ended();
  await sleep(20);
  if (r.log.indexOf('started:a') >= 0 && r.log.indexOf('completed:a') >= 0
      && r.log.indexOf('play:b') > r.log.indexOf('completed:a'))
    ok('the gesture resumed it, and the queue followed');
  else bad('the resume must flow through started/completed and advance',
           r.log.join(' | '));
}

// --- 4b: no refusal policy — the refusal is a failure like any other --------

async function testRefusalWithoutPolicy() {
  console.log('');
  console.log('no refusal policy (the table): the refusal fails and advances:');
  const r = rig({ script: { b: 'end' } });
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  await sleep(5);
  r.clips.a.rejected({ name: 'NotAllowedError' });
  await sleep(100);
  const fails = only(r.log, 'failed');
  if (fails.length === 1 && /autoplay refused/.test(fails[0]) && r.q.isDead('a'))
    ok('the refusal is witnessed as a failure and the key is dead');
  else bad('an unheld refusal must settle as autoplay refused',
           r.log.join(' | '));
  await sleep(40);
  if (r.log.indexOf('completed:b') >= 0)
    ok('and the clip behind it still sounded');
  else bad('the queue must advance past it', r.log.join(' | '));
}

// --- 5: the never-started bound, its re-arm, and the duck -------------------

async function testNeverStartedBound() {
  console.log('');
  console.log('a clip that never starts is given up on at the bound:');
  const r = rig({ script: { b: 'end' } });
  r.q.enqueue({ key: 'a' });             // manual: no signal ever
  r.q.enqueue({ key: 'b' });
  await sleep(220);
  const fails = only(r.log, 'failed');
  if (fails.length === 1 && /never started: gave up waiting/.test(fails[0]))
    ok('its own distinct failure, once');
  else bad('the bound must fail the silent clip', r.log.join(' | '));
  if (r.log.indexOf('unload:a:gaveup') >= 0)
    ok('the wedged clip is unloaded with the gaveup outcome');
  else bad('unload must carry gaveup', r.log.join(' | '));
  if (r.log.indexOf('completed:b') >= 0 && !r.q.busy())
    ok('the queue is freed behind it');
  else bad('the queue must drain', r.log.join(' | '));
  if (!r.log.some(l => l === 'started:a' || l === 'completed:a'))
    ok('and it is never reported played');
  else bad('no play claim may survive', r.log.join(' | '));
}

async function testProgressRearms() {
  console.log('');
  console.log('loading progress re-arms the bound instead of expiring it:');
  const r = rig();
  r.q.enqueue({ key: 'a' });
  for (let i = 0; i < 4; i++) {          // progress every 60ms against a 120ms bound
    await sleep(60);
    r.clips.a.progress();
  }
  if (only(r.log, 'failed').length === 0)
    ok('a slow load with bytes arriving is not shot');
  else bad('progress must re-arm the clock', r.log.join(' | '));
  r.clips.a.playing();
  r.clips.a.ended();
  await sleep(20);
  if (r.log.indexOf('completed:a') >= 0)
    ok('and it completes once it finally sounds');
  else bad('the re-armed clip must still complete', r.log.join(' | '));
}

async function testStartedNeverCut() {
  console.log('');
  console.log('a clip that started is never cut by the bound:');
  const r = rig();
  r.q.enqueue({ key: 'a' });
  await sleep(5);
  r.clips.a.playing();                   // audio flows at once
  await sleep(300);                      // far past the bound
  if (only(r.log, 'failed').length === 0 && r.log.indexOf('started:a') >= 0)
    ok('no failure was invented for a sounding clip');
  else bad('a sounding clip must never be failed', r.log.join(' | '));
}

async function testDuckDefersBound() {
  console.log('');
  console.log('a ducked clip is not stuck: the bound waits out the duck:');
  let ducked = true;
  const r = rig({ isDucked: () => ducked });
  r.q.enqueue({ key: 'a' });
  await sleep(300);                      // far past the bound, all of it ducked
  if (only(r.log, 'failed').length === 0)
    ok('the bound re-arms while the microphone is open');
  else bad('a duck must defer the give-up', r.log.join(' | '));
  ducked = false;
  await sleep(300);                      // now the clock runs for real
  if (only(r.log, 'failed').length === 1
      && /never started/.test(only(r.log, 'failed')[0]))
    ok('and fires once the duck lifts with still nothing sounding');
  else bad('the bound must resume after the duck', r.log.join(' | '));
}

// --- 6: ended-without-start is a failure wearing a completion's clothes -----

async function testEndedWithoutStart() {
  console.log('');
  console.log('an ended nothing ever sounded is a failure, never a completion:');
  const r = rig();
  r.q.enqueue({ key: 'a' });
  await sleep(5);
  r.clips.a.ended();                     // no playing, no timeupdate, just ended
  await sleep(20);
  const fails = only(r.log, 'failed');
  if (fails.length === 1 && /ended without ever sounding/.test(fails[0])
      && only(r.log, 'completed').length === 0)
    ok('reported as its own failure, never completed');
  else bad('ended-without-start must fail', r.log.join(' | '));
}

// --- 7: drop-queued spares the sounding clip; stopAll is silent -------------

async function testDropQueuedSparesCurrent() {
  console.log('');
  console.log('dropQueued: the backlog goes, the sounding clip plays out:');
  const r = rig();
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  r.q.enqueue({ key: 'c' });
  await sleep(5);
  r.clips.a.playing();                   // a is sounding
  r.q.dropQueued();
  r.clips.a.ended();
  await sleep(40);
  if (r.log.indexOf('completed:a') >= 0)
    ok('the clip already sounding was never cut');
  else bad('dropQueued must not touch the current clip', r.log.join(' | '));
  if (only(r.log, 'play').length === 1 && !r.q.busy())
    ok('nothing queued behind it ever played');
  else bad('the backlog must be gone', r.log.join(' | '));
}

async function testStopAllSilent() {
  console.log('');
  console.log('stopAll: everything goes, silently — the page owns the witness:');
  const r = rig();
  r.q.enqueue({ key: 'a' });
  r.q.enqueue({ key: 'b' });
  await sleep(5);
  r.q.stopAll();
  await sleep(40);
  if (r.log.indexOf('unload:a:stopped') >= 0)
    ok('the current clip is unloaded with the stopped outcome');
  else bad('stopAll must unload the current clip', r.log.join(' | '));
  if (only(r.log, 'failed').length === 0 && only(r.log, 'completed').length === 0)
    ok('no failure and no completion is invented for a chosen stop');
  else bad('the stop must be silent', r.log.join(' | '));
  if (!r.q.busy() && only(r.log, 'play').length === 1)
    ok('the queue is empty and nothing else played');
  else bad('stopAll must end everything', r.log.join(' | '));
  if (!r.q.isDead('a'))
    ok('a stopped clip is not marked dead — silence was chosen, not failed');
  else bad('stopped must not poison the key', 'dead');
}

// --- 8: the dequeue-time gate (the table toggle) ----------------------------

async function testShouldPlayGate() {
  console.log('');
  console.log('shouldPlay false at dequeue empties the queue silently:');
  let on = true;
  const r = rig({ shouldPlay: () => on, script: { a: 'end' } });
  r.q.enqueue({ key: 'a' });
  await sleep(60);
  if (r.log.indexOf('completed:a') >= 0) ok('gate open: the clip sounds');
  else bad('the gate must not block an open toggle', r.log.join(' | '));
  on = false;
  r.q.enqueue({ key: 'b' });
  r.q.enqueue({ key: 'c' });
  await sleep(60);
  if (only(r.log, 'play').length === 1 && only(r.log, 'failed').length === 0
      && !r.q.busy())
    ok('gate closed: nothing plays, nothing is failed, the queue drains');
  else bad('a closed gate must drain silently', r.log.join(' | '));
}

(async () => {
  await testOrderSerialOnce();
  await testDeadStateTerminal();
  await testRejectionFirstRace();
  await testErrorFirstRace();
  await testOtherRejectionIgnored();
  await testRefusalHoldAndResume();
  await testRefusalWithoutPolicy();
  await testNeverStartedBound();
  await testProgressRearms();
  await testStartedNeverCut();
  await testDuckDefersBound();
  await testEndedWithoutStart();
  await testDropQueuedSparesCurrent();
  await testStopAllSilent();
  await testShouldPlayGate();
  console.log('');
  console.log(PASS + ' passed, ' + FAIL + ' failed');
  process.exit(FAIL === 0 ? 0 : 1);
})();
