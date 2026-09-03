// Drives the shipped chess client's kept wire (specs/chessweb.md rule 25):
// a page whose socket drops redials by itself — exponential backoff from the
// base doubling to the cap, jittered, indefinitely; a hidden page holds its
// hand and a return to visibility (or the network coming back) redials at
// once with the backoff reset; a redial that lands resumes the old role
// uninvited so rule 3's join sync (Team + replay) repaints the board from
// the store, and the status word / greyed board say the truth while the
// wire is down. Until 2026-09-03 a dropped connection left a live-looking
// board silently frozen mid-game — every case here is red against that.
//
// The technique is the chat harness's (tests/chess_client_chat_test.js):
// the functions are lifted out of lib/chessweb_client/board.js and run with
// every free name supplied — fake WebSocket, fake timers, pinned
// Math.random — so a rename fails loudly rather than silently testing
// nothing, and nothing here touches a network, a server, or a model.
//
// Run: node tests/chess_client_reconnect_test.js   (or through
//      tests/test_chessweb_reconnect.sh)
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = fs.readFileSync(
	path.join(__dirname, '..', 'lib', 'chessweb_client', 'board.js'), 'utf8');

let PASS = 0, FAIL = 0;
const ok = m => { PASS++; console.log('  ok: ' + m); };
const bad = (m, got) => {
	FAIL++;
	console.log('  FAIL: ' + m + ' — got [' + got + ']');
};

// The knobs are read from board.js itself so this file never drifts from
// the shipped numbers; their absence is a loud red, not a crash.
const baseM = /const RECONN_BASE_MS = (\d+), RECONN_CAP_MS = (\d+)/.exec(SRC);
const triesM = /const REJOIN_TRIES = (\d+)/.exec(SRC);
const BASE = baseM ? +baseM[1] : 1000;
const CAP = baseM ? +baseM[2] : 30000;
const TRIES = triesM ? +triesM[1] : 3;

const MT = {PING: 0, JOIN: 1, NEWGAME: 2, MOVE: 3, ERROR: 4, TEAM: 5,
            PLAYER: 6, OPPONENT_LEFT: 7, OPPONENT_JOINED: 8, PROMOTE: 9,
            GAME_COMPLETE: 10};

function liftOne(name) {
	for (const head of ['async function ' + name + '(',
	                    'function ' + name + '(']) {
		const start = SRC.indexOf(head);
		if (start < 0) continue;
		const end = SRC.indexOf('\n}\n', start);
		if (end < 0) break;
		return SRC.slice(start, end + 3);
	}
	return null;
}

const NAMES = ['connect', 'openSocket', 'scheduleReconnect', 'reconnectNow',
               'resumeRole', 'sendJoin', 'linkWord', 'paintLink',
               'setConnected', 'sendMsg', 'sendPing', 'enc', 'fieldsOf',
               'drain', 'handle', 'applyWireMove', 'clearPendingFor',
               'pieceOn', 'initialPieces'];

function makeTimers() {
	let nextId = 1;
	const q = new Map();
	return {
		set(fn, ms) { const id = nextId++; q.set(id, {fn, ms}); return id; },
		clear(id) { q.delete(id); },
		// fire the soonest pending timer; returns the delay it was set with
		fireNext() {
			let best = null, bid = null;
			for (const [id, t] of q)
				if (!best || t.ms < best.ms) { best = t; bid = id; }
			if (!best) return null;
			q.delete(bid);
			best.fn();
			return best.ms;
		},
		pending() { return [...q.values()].map(t => t.ms); },
	};
}

function makeCtx() {
	const els = {};
	const el = id => {
		if (els[id]) return els[id];
		const cls = new Set();
		els[id] = {
			id, value: '', textContent: '', className: '',
			disabled: false, hidden: false, _cls: cls,
			classList: {
				add: c => cls.add(c),
				remove: c => cls.delete(c),
				toggle: (c, on) => {
					const want = on === undefined ? !cls.has(c) : !!on;
					if (want) cls.add(c); else cls.delete(c);
				},
				contains: c => cls.has(c),
			},
		};
		return els[id];
	};
	el('serveraddr').value = '127.0.0.1:9';

	const timers = makeTimers();
	const state = {sockets: [], consoleLines: [], fetchStates: 0,
	               resets: 0, els, timers};

	class FakeWS {
		constructor(url) {
			this.url = url;
			this.readyState = 0;
			this.sent = [];
			state.sockets.push(this);
		}
		send(u) { this.sent.push(Array.from(u)); }
		close() { this.readyState = 3; }
	}

	const stubEl = () => ({
		classList: {add() {}, remove() {}},
		style: {}, remove() {},
		querySelector: () => ({setAttribute() {}}),
	});

	const ctx = {
		// page state the lifted functions read and write, via with()
		ws: null, rxbuf: [], seated: false, black: false, gameOver: false,
		ply: 0, pieces: [], grave: {w: [], b: []}, legal: null,
		selected: null, drag: null, pendingSend: null, promoPending: null,
		lastMove: null, squares: [], stateTimer: null, statePoll: null,
		stateRetries: 0, gameId: null, resignArm: null, clockState: null,
		chatPoll: null, chatBusy: false,
		wantLive: false, reconnTimer: null, reconnDelay: 0,
		reconnRole: null, rejoinsLeft: 0, rejoinWait: false,
		rejoinTimer: null,
		// the shipped knobs, read off the source above
		RECONN_BASE_MS: BASE, RECONN_CAP_MS: CAP, REJOIN_TRIES: TRIES,
		MT, REGULAR: 0, EN_PASSANT: 1, CASTLE_LEFT: 2, CASTLE_RIGHT: 3,
		// the world
		WebSocket: FakeWS,
		document: {hidden: false},
		navigator: {onLine: true},
		Math: {min: Math.min, max: Math.max, floor: Math.floor,
		       round: Math.round, hypot: Math.hypot, random: () => 1},
		setTimeout: (fn, ms) => timers.set(fn, ms),
		clearTimeout: id => timers.clear(id),
		setInterval: () => 0,
		clearInterval: () => {},
		// page stubs the lifted code leans on
		$: el,
		log: line => state.consoleLines.push(String(line)),
		fetchState: () => { state.fetchStates++; },
		updateTurnline() {}, disarmResign() {}, pollChat() {},
		position() {}, markLast() {}, clearMarks() {}, clearSelection() {},
		scheduleState() {}, renderGraves() {}, updateResign() {},
		showBanner() {}, fetchChatRecord() {}, snapBack() {},
		promptPromotion() {}, applyPromotion() {},
		kill: v => { v.alive = false; },
		resetBoard: () => {
			state.resets++;
			ctx.pieces = ctx._mk ? ctx._mk() : [];
			ctx.ply = 0;
			ctx.gameOver = false;
			ctx.lastMove = null;
			ctx.legal = null;
			ctx.pendingSend = null;
			ctx.promoPending = null;
		},
	};
	ctx._state = state;
	ctx._stubEl = stubEl;
	return ctx;
}

function build(ctx) {
	const found = NAMES.map(liftOne).filter(Boolean);
	const exported = NAMES.filter(n => liftOne(n) !== null);
	// Non-strict on purpose: `with` is what lets the lifted code read and
	// WRITE the page-level lets (ws, reconnDelay, ...) as ctx's own.
	const api = new Function('ctx', 'with (ctx) {\n' + found.join('\n') +
		'\nreturn {' + exported.join(',') + '};\n}')(ctx);
	if (api.initialPieces)
		ctx._mk = () => api.initialPieces()
			.map(p => Object.assign({}, p, {el: ctx._stubEl()}));
	const missing = ['openSocket', 'scheduleReconnect', 'reconnectNow',
	                 'resumeRole', 'paintLink'].filter(n => !api[n]);
	if (missing.length)
		bad('board.js has no reconnect machinery', 'missing ' +
		    missing.join(', '));
	return api;
}

// --- the wire helpers ------------------------------------------------------
const srvOpen = s => { s.readyState = 1; if (s.onopen) s.onopen(); };
const srvClose = s => { s.readyState = 3; if (s.onclose) s.onclose(); };
// Server framing: type byte, one-byte uvarint length, payload.
const feed = (s, type, payload) => s.onmessage(
	{data: new Uint8Array([type, payload.length].concat(payload))});
const errBytes = text => {
	const b = Array.from(new TextEncoder().encode(text));
	return [0x0A, b.length].concat(b); // field 1, length-delimited
};
const lastSock = ctx => ctx._state.sockets[ctx._state.sockets.length - 1];
const word = ctx => ctx._state.els['connword']
	? ctx._state.els['connword'].textContent : '';
const stale = ctx => ctx._state.els['boardwrap']._cls.has('stale');
const joinFrames = s => s.sent.filter(f => f[0] === MT.JOIN);

// --- 1: a drop schedules a retry; retries back off to the cap, forever ----
function testBackoff() {
	console.log('a dropped connection retries, backing off to the cap:');
	if (!baseM)
		bad('board.js carries no RECONN_BASE_MS/RECONN_CAP_MS knobs',
		    'no match in source');
	else if (BASE >= 500 && BASE <= 2000 && CAP >= 20000 && CAP <= 45000)
		ok('the shipped knobs are near 1s and ~30s (' + BASE + '/' + CAP
		   + 'ms)');
	else
		bad('the backoff must start near 1s and cap near 30s',
		    BASE + '/' + CAP);
	if (/scheduleReconnect[\s\S]{0,400}Math\.random/.test(SRC))
		ok('the redial wait is jittered (Math.random in the schedule)');
	else
		bad('the redial wait must carry jitter', 'no Math.random near '
		    + 'scheduleReconnect');

	const ctx = makeCtx();
	const api = build(ctx);
	api.connect();
	const s1 = lastSock(ctx);
	if (ctx._state.sockets.length === 1) ok('Connect dials one socket');
	else bad('Connect must dial', ctx._state.sockets.length + ' sockets');
	srvOpen(s1);
	srvClose(s1);
	const first = ctx._state.timers.pending();
	if (first.length === 1 && first[0] === BASE)
		ok('the drop scheduled a redial at the base delay ('
		   + BASE + 'ms with jitter pinned)');
	else
		bad('a dropped connection must schedule a retry near 1s',
		    first.join(',') || 'no timer at all');

	// Every redial fails; the waits must double and pin at the cap.
	const observed = [];
	for (let i = 0; i < 8; i++) {
		const ms = ctx._state.timers.fireNext();
		if (ms === null) break;
		observed.push(ms);
		srvClose(lastSock(ctx)); // the dial failed; onclose fires
	}
	const want = [];
	let d = BASE;
	for (let i = 0; i < 8; i++) {
		want.push(d);
		d = Math.min(d * 2, CAP);
	}
	if (observed.join(',') === want.join(','))
		ok('eight failed rounds backed off ' + observed.join(', '));
	else
		bad('retries must double from the base and pin at the cap ('
		    + want.join(',') + ')', observed.join(',') || 'none');
	if (ctx._state.timers.pending().length === 1)
		ok('and a ninth redial is still scheduled — retrying never stops');
	else
		bad('the page must keep retrying indefinitely',
		    ctx._state.timers.pending().length + ' pending');

	// A hidden page holds its hand; visibility's return redials at once
	// with the backoff reset.
	ctx.document.hidden = true;
	const dialsBefore = ctx._state.sockets.length;
	ctx._state.timers.fireNext();
	if (ctx._state.sockets.length === dialsBefore)
		ok('a hidden page does not dial');
	else
		bad('a hidden page must hold its hand',
		    ctx._state.sockets.length - dialsBefore + ' dial(s)');
	ctx.document.hidden = false;
	api.reconnectNow(); // what the visibilitychange/online wiring calls
	if (ctx._state.sockets.length === dialsBefore + 1)
		ok('back to visible: an immediate redial, no timer waited on');
	else
		bad('visibility\'s return must redial at once',
		    ctx._state.sockets.length - dialsBefore + ' dial(s)');
	srvClose(lastSock(ctx));
	const reset = ctx._state.timers.pending();
	if (reset.length === 1 && reset[0] === BASE)
		ok('and the backoff was reset — the next wait is the base again');
	else
		bad('reconnectNow must reset the backoff', reset.join(',') || 'none');
}

// --- 2: the status word — never a live-looking dead board ------------------
function testStatusWord() {
	console.log('');
	console.log('the status word says connected / reconnecting / offline:');
	const ctx = makeCtx();
	const api = build(ctx);
	api.connect();
	srvOpen(lastSock(ctx));
	if (word(ctx) === 'connected'
			&& ctx._state.els['connstate']._cls.has('on'))
		ok('a live wire reads connected, dot lit');
	else
		bad('a live wire must read connected', '[' + word(ctx) + ']');
	if (!stale(ctx)) ok('and the board is not greyed while live');
	else bad('a live board must not be greyed', 'stale set');
	srvClose(lastSock(ctx));
	if (word(ctx) === 'reconnecting…')
		ok('a dropped wire reads reconnecting — never silent');
	else
		bad('a dropped wire must say reconnecting, not look live',
		    '[' + word(ctx) + ']');
	if (stale(ctx))
		ok('and the board is visibly greyed — a photograph, not a game');
	else
		bad('a dead wire must grey the board', 'no stale class');
	ctx.navigator.onLine = false;
	api.paintLink(); // what the offline listener calls
	if (word(ctx) === 'offline')
		ok('the browser\'s own no-network verdict reads offline');
	else
		bad('no network must read offline', '[' + word(ctx) + ']');
	ctx.navigator.onLine = true;
	ctx.document.hidden = false;
	api.reconnectNow();
	srvOpen(lastSock(ctx));
	if (word(ctx) === 'connected' && !stale(ctx))
		ok('the redial that lands reads connected and un-greys the board');
	else
		bad('a landed redial must repaint the word and the board',
		    '[' + word(ctx) + '] stale=' + stale(ctx));
}

// --- 3: a reconnect resyncs — the outage's move appears --------------------
function testResync() {
	console.log('');
	console.log('a redial resumes the seat and the outage\'s move appears:');
	const ctx = makeCtx();
	const api = build(ctx);
	api.connect();
	const s1 = lastSock(ctx);
	srvOpen(s1);
	ctx.reconnRole = 'player'; // the Join click's memory
	feed(s1, MT.PLAYER, api.enc([[1, 1]]));
	feed(s1, MT.TEAM, []); // white; the board resets and replays (empty)
	if (ctx.seated && ctx._state.resets === 1 && ctx.ply === 0)
		ok('seated on the first wire, board synced at ply 0');
	else
		bad('priming: the seat never landed', 'seated=' + ctx.seated
		    + ' resets=' + ctx._state.resets + ' ply=' + ctx.ply);
	srvClose(s1);
	// The opponent's move lands in the store while the page is dark.
	ctx._state.timers.fireNext();
	const s2 = lastSock(ctx);
	if (s2 !== s1) ok('the redial dialed a fresh socket');
	else bad('the redial never dialed', 'same socket');
	const fetches = ctx._state.fetchStates;
	srvOpen(s2);
	const joins = joinFrames(s2);
	if (joins.length === 1 && joins[0].join(',') === '1,2,8,1')
		ok('the seat re-Joined as player by itself — rule 3\'s sync asked '
		   + 'for, uninvited');
	else
		bad('a landed redial must re-Join the old role',
		    s2.sent.map(f => f.join(',')).join(' | ') || 'nothing sent');
	if (ctx._state.fetchStates > fetches)
		ok('and the /state photograph was refetched at once');
	else
		bad('a landed redial must refetch /state', 'no fetch');
	// The server's join sync: Player, Team, and the replay — including the
	// move recorded during the outage (white e2e4 in wire coords).
	feed(s2, MT.PLAYER, api.enc([[1, 1]]));
	feed(s2, MT.TEAM, []);
	feed(s2, MT.MOVE, api.enc([[1, 4], [2, 6], [3, 4], [4, 4]]));
	if (ctx._state.resets === 2)
		ok('Team reset the board — the store\'s truth, not the page\'s '
		   + 'memory');
	else
		bad('the resync must rebuild rather than trust the kept board',
		    ctx._state.resets + ' reset(s)');
	const pawn = api.pieceOn(4, 4);
	if (ctx.ply === 1 && pawn && pawn.w && pawn.t === 'P'
			&& api.pieceOn(4, 6) === null)
		ok('the move made during the outage is on the board — never missed');
	else
		bad('the outage\'s move must appear after the resync',
		    'ply=' + ctx.ply + ' at(4,4)='
		    + (pawn ? pawn.t : 'nothing'));
}

// --- 4: a watcher resumes as a watcher -------------------------------------
function testWatcherResumes() {
	console.log('');
	console.log('a watcher comes back as a watcher:');
	const ctx = makeCtx();
	const api = build(ctx);
	api.connect();
	srvOpen(lastSock(ctx));
	ctx.reconnRole = 'watcher';
	srvClose(lastSock(ctx));
	ctx._state.timers.fireNext();
	const s2 = lastSock(ctx);
	srvOpen(s2);
	const joins = joinFrames(s2);
	if (joins.length === 1 && joins[0].join(',') === '1,0')
		ok('the redial re-Joined as spectator — Team and replay follow');
	else
		bad('a watcher must resume as a watcher',
		    s2.sent.map(f => f.join(',')).join(' | ') || 'nothing sent');
	if (!ctx.rejoinWait)
		ok('and no seat wait was armed for a join that cannot be refused');
	else
		bad('a spectator join must not arm the seat retry', 'rejoinWait');
}

// --- 5: the dead chair is re-asked, bounded, then given up out loud --------
function testSeatRetry() {
	console.log('');
	console.log('a seat the probe frees late is re-asked, bounded:');
	const ctx = makeCtx();
	const api = build(ctx);
	api.connect();
	srvOpen(lastSock(ctx));
	ctx.reconnRole = 'player';
	feed(lastSock(ctx), MT.PLAYER, api.enc([[1, 1]]));
	srvClose(lastSock(ctx));
	ctx._state.timers.fireNext();
	const s2 = lastSock(ctx);
	srvOpen(s2);
	// The server refuses every ask (the chair looks held); each refusal
	// but the last must schedule one more ask.
	let asks = joinFrames(s2).length;
	while (joinFrames(s2).length < TRIES + 2) {
		feed(s2, MT.ERROR, errBytes('That seat is taken'));
		const fired = ctx._state.timers.fireNext();
		if (fired === null) break;
		if (joinFrames(s2).length === asks) break;
		asks = joinFrames(s2).length;
	}
	if (joinFrames(s2).length === TRIES)
		ok('the seat was asked for exactly ' + TRIES
		   + ' times, then no more');
	else
		bad('the re-ask must be bounded at ' + TRIES,
		    joinFrames(s2).length + ' ask(s)');
	if (ctx._state.consoleLines.some(l => /seat would not come back/.test(l)))
		ok('and the give-up is witnessed in the console — never silent');
	else
		bad('an unseated board must say so out loud',
		    ctx._state.consoleLines.join(' | ') || 'nothing');

	// The happy path: the second ask lands and the wait disarms.
	const c2 = makeCtx();
	const b2 = build(c2);
	b2.connect();
	srvOpen(lastSock(c2));
	c2.reconnRole = 'player';
	feed(lastSock(c2), MT.PLAYER, b2.enc([[1, 1]]));
	srvClose(lastSock(c2));
	c2._state.timers.fireNext();
	const t2 = lastSock(c2);
	srvOpen(t2);
	feed(t2, MT.ERROR, errBytes('That seat is taken'));
	c2._state.timers.fireNext(); // the 1.5s re-ask
	feed(t2, MT.PLAYER, b2.enc([[1, 1]]));
	feed(t2, MT.ERROR, errBytes('some later refusal'));
	if (c2.seated && !c2.rejoinWait
			&& c2._state.timers.pending().length === 0)
		ok('a seat that came back on the re-ask disarms the wait — a '
		   + 'later Error books no join');
	else
		bad('Player must clear the rejoin wait',
		    'seated=' + c2.seated + ' wait=' + c2.rejoinWait
		    + ' timers=' + c2._state.timers.pending().join(','));
}

// A board.js with no reconnect machinery must count as red on every case,
// not crash the file: each scenario's throw is its own loud failure.
for (const t of [testBackoff, testStatusWord, testResync,
                 testWatcherResumes, testSeatRetry]) {
	try {
		t();
	} catch (e) {
		bad(t.name + ' aborted', (e && e.message) || String(e));
	}
}
console.log('');
console.log('chess client reconnect: ' + PASS + ' passed, ' + FAIL
            + ' failed');
process.exit(FAIL ? 1 : 0);
