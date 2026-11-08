// The one browser voice queue — the playback mechanics the phone page and the
// chess table's page share (specs/phone.md rule 44c; specs/chessweb.md rules
// 24e and 24g). One implementation of the discipline phone.md rules 44a-44b
// name: arrival-order serial playback, each clip exactly once and never two
// sounding together; a terminal per-clip dead state consulted at enqueue; the
// refusal grace, inside which a racing error event claims a clip before any
// refusal verdict is believed; started/completed truth taken only from element
// events fed into the per-clip handle; the progress-rearmed never-started
// bound, deferred while the page says the clip is deliberately ducked; and
// queue advancement after every terminal outcome.
//
// This file is NEUTRAL (chessweb.md rule 24g): it knows no server, no route,
// no secret, no conversation, and no chess. Everything with a side to it is a
// policy callback the page supplies — the phone's /played reporting and ▶
// gesture recovery, the table's console witness and speak-toggle gate. Both
// servers serve this same file, byte for byte, each through its own route;
// the node harnesses require() it directly, which is why it is UMD.
//
// createVoiceQueue(opts) — opts:
//   play(item, clip)      REQUIRED. Begin loading/playing `item`, wiring the
//                         media element's events into the handle: clip.playing(),
//                         clip.timeupdate(seconds), clip.progress(), clip.ended(),
//                         clip.error(detail), clip.rejected(err) for the play()
//                         promise's rejection, clip.failed(why) for a failure
//                         the page saw itself (a fetch, a decode).
//   unload(item, outcome) Called once per clip on its terminal outcome —
//                         "completed", "failed", "gaveup", or "stopped" — so
//                         the page can unload its element / revoke its URL.
//   onRequested(item)     A clip joined the queue.
//   onStarted(item)       Audio actually flowed — the element's own truth.
//   onCompleted(item)     It ended AFTER starting; an ended nothing ever
//                         sounded is a failure wearing a completion's clothes
//                         and lands on onFailed instead (rule 44b).
//   onFailed(item, why)   The clip's one terminal failure, after the dead
//                         mark: "media error …", "never started: gave up
//                         waiting", "ended without ever sounding", "autoplay
//                         refused", or the page's own why via clip.failed().
//   onRefusal(item)       A genuine NotAllowedError no error event claimed
//                         inside the grace. Return true to HOLD the clip for
//                         a gesture — the queue parks behind it (advancing
//                         would only meet the same refusal) and the element's
//                         playing event resumes it. Absent or false, the
//                         refusal settles as the failure "autoplay refused".
//   onDeadEnqueue(item)   A clip whose key is already dead was offered again
//                         and skipped (never refetched, rule 44a).
//   onChange()            Any state change worth redrawing a control over.
//   shouldPlay()          Consulted when a clip is dequeued; false empties
//                         the queue silently (the table's speak toggle).
//   isDucked()            True while the current clip is paused on purpose
//                         (the open microphone): a ducked clip is not stuck,
//                         so the give-up clock re-arms instead of firing.
//   deadKey(item)         The dead state's key. Defaults to item.key, then
//                         item.url.
//   startGraceMs          The never-started bound (default 10000).
//   refusalGraceMs        The refusal grace (default 250).
//
// Returns: { enqueue(item), dropQueued(), stopAll(), busy(), queuedCount(),
//            currentItem(), firstQueued(), isDead(key), markDead(key) }.
// dropQueued empties what waits and never cuts the clip already sounding;
// stopAll cuts everything SILENTLY (outcome "stopped", no witnesses) — the
// page already said what happened, in its own words.
(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BrowserVoiceQueue = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function createVoiceQueue(opts) {
    opts = opts || {};
    if (typeof opts.play !== 'function')
      throw new Error('createVoiceQueue: a play(item, clip) policy is required');
    var startGraceMs = opts.startGraceMs > 0 ? opts.startGraceMs : 10000;
    var refusalGraceMs = opts.refusalGraceMs > 0 ? opts.refusalGraceMs : 250;
    var deadKey = typeof opts.deadKey === 'function'
      ? opts.deadKey
      : function (item) { return item && (item.key != null ? item.key : item.url); };
    function call(name, a, b) {
      if (typeof opts[name] === 'function') return opts[name](a, b);
    }

    var queue = [];        // items awaiting their turn to sound
    var current = null;    // {item, started, settled, held, watchdog}
    var dead = {};         // key -> true: failed for good (rule 44a)

    function isDead(key) {
      return key != null && Object.prototype.hasOwnProperty.call(dead, key);
    }
    function markDead(key) {
      if (key != null) dead[String(key)] = true;
    }

    function disarmWatchdog(c) {
      if (c.watchdog) { clearTimeout(c.watchdog); c.watchdog = null; }
    }

    // The give-up clock on a clip that neither sounds nor fails (rule 44b):
    // armed the moment the clip is handed to play() — the load is inside the
    // bound — re-armed by loading progress, deferred while ducked, and
    // disarmed the moment audio flows. A clip that started is never cut.
    function armWatchdog(c) {
      disarmWatchdog(c);
      c.watchdog = setTimeout(function () {
        c.watchdog = null;
        if (c !== current || c.started || c.settled || c.held) return;
        if (call('isDucked')) { armWatchdog(c); return; }
        settle(c, 'gaveup', 'never started: gave up waiting');
      }, startGraceMs);
    }

    // One terminal outcome per clip, whatever says it twice: dead mark BEFORE
    // the witness (rule 44a — the signal still to land can then neither
    // re-report nor re-offer it), then the advance, deferred a microtask so a
    // successor's play() never runs inside the dying clip's own event.
    function settle(c, outcome, why) {
      if (c.settled) return;
      c.settled = true;
      c.held = false;
      disarmWatchdog(c);
      if (c === current) current = null;
      if (outcome === 'failed' || outcome === 'gaveup') markDead(deadKey(c.item));
      call('unload', c.item, outcome);
      if (outcome === 'completed') call('onCompleted', c.item);
      else if (outcome !== 'stopped') call('onFailed', c.item, why);
      if (outcome !== 'stopped') advance();
      call('onChange');
    }

    function advance() {
      Promise.resolve().then(playNext);
    }

    function started(c) {
      if (c.settled || c.started) return;
      c.started = true;
      c.held = false;         // a held clip that sounds resumed by the gesture
      disarmWatchdog(c);
      call('onStarted', c.item);
      call('onChange');
    }

    // The play() rejection (rules 44-44a): a source that failed to load
    // signals twice, in EITHER order — the element's error event, which owns
    // the failure, and the rejection, whose name can read NotAllowedError on
    // the measured rejection-first ordering. So nothing but a genuine refusal
    // is ever acted on, and a refusal verdict waits a beat: if the error
    // event (or any other terminal signal) claims the clip inside the grace,
    // it has already said everything.
    function rejected(c, err) {
      if (c.settled) return;
      if (!err || err.name !== 'NotAllowedError') return;
      setTimeout(function () {
        if (c.settled) return;               // the error event owned it
        if (isDead(deadKey(c.item))) return; // dead by any signal: owned too
        if (c !== current) return;           // the queue moved on
        disarmWatchdog(c);                   // waiting on a tap, not stuck
        if (call('onRefusal', c.item) === true) {
          c.held = true;                     // parked behind the gesture
          call('onChange');
          return;
        }
        settle(c, 'failed', 'autoplay refused');
      }, refusalGraceMs);
    }

    function makeClip(c) {
      return {
        playing: function () { started(c); },
        timeupdate: function (t) { if (t > 0) started(c); },
        progress: function () {
          // Bytes are arriving: a slow load is not a dead one. Re-arm.
          if (c === current && c.watchdog && !c.started && !c.settled)
            armWatchdog(c);
        },
        ended: function () {
          if (c.settled) return;
          if (c.started) settle(c, 'completed');
          // An ended nothing ever sounded is a failure wearing a
          // completion's clothes (rule 44b).
          else settle(c, 'failed', 'ended without ever sounding');
        },
        error: function (detail) {
          if (c.settled) return;
          settle(c, 'failed', detail || 'media error');
        },
        failed: function (why) {
          if (c.settled) return;
          settle(c, 'failed', why || 'failed');
        },
        rejected: function (err) { rejected(c, err); },
        isCurrent: function () { return c === current && !c.settled; },
      };
    }

    function playNext() {
      if (current || !queue.length) return;
      if (typeof opts.shouldPlay === 'function' && !opts.shouldPlay()) {
        // Silence chosen is silence now: the whole backlog goes with the
        // dequeued clip, silently (the table's toggle, rule 24e).
        queue.length = 0;
        call('onChange');
        return;
      }
      var c = { item: queue.shift(), started: false, settled: false,
                held: false, watchdog: null };
      current = c;
      var clip = makeClip(c);
      armWatchdog(c);
      call('onChange');
      try {
        opts.play(c.item, clip);
      } catch (e) {
        clip.failed('play threw: ' + ((e && e.message) || e));
      }
    }

    function enqueue(item) {
      if (isDead(deadKey(item))) {
        // Failed for good (rule 44a): never refetched, never retried.
        call('onDeadEnqueue', item);
        return;
      }
      queue.push(item);
      call('onRequested', item);
      playNext();
      // The phantom playing state (rule 44b's tail): a queue believing a clip
      // is playing, nothing ever sounded, and no give-up clock riding the
      // load adopts the stuck clip under the same clock, so it fails on the
      // record and frees the queue. A clip held for a gesture is waiting,
      // not stuck.
      if (current && !current.started && !current.held && !current.settled
          && !current.watchdog)
        armWatchdog(current);
      call('onChange');
    }

    function dropQueued() {
      // The clip already sounding plays out; nothing queued behind it will.
      queue.length = 0;
      call('onChange');
    }

    function stopAll() {
      // The chosen stop: everything goes, silently — no witness, no advance.
      queue.length = 0;
      if (current) settle(current, 'stopped');
      call('onChange');
    }

    return {
      enqueue: enqueue,
      dropQueued: dropQueued,
      stopAll: stopAll,
      busy: function () { return !!current || queue.length > 0; },
      queuedCount: function () { return queue.length; },
      currentItem: function () { return current ? current.item : null; },
      firstQueued: function () { return queue.length ? queue[0] : null; },
      isDead: isDead,
      markDead: markDead,
    };
  }

  return { createVoiceQueue: createVoiceQueue };
}));
