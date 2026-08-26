// Drives the shipped chess client's table-chat voice path — pollChat and the
// clip queue — against stubs, by lifting the functions out of
// lib/chessweb_client/board.js and evaluating them with every free name
// supplied (the phone client tests' own technique: the page has no module
// boundary, so this is the only way to run its logic without a browser, and
// a rename fails loudly rather than silently testing nothing).
//
// Run: node tests/chess_client_chat_test.js   (or through
//      tests/test_chess_chat_playback.sh)
//
// What it holds (specs/chessweb.md rule 24e, the queue discipline): every
// message of hers that arrives while the toggle is on is voiced exactly once,
// in order, one clip at a time; a dead or never-starting clip is given up on
// with a console witness and the queue advances; a sounding clip is never cut
// by the give-up bound; history, resets, the toggle, and other roles' lines
// are never voiced. The first shipped shape spoke at most one clip per poll
// batch — "one clip per batch is plenty" — and lost the rest with no witness:
// these cases are red against it.
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
const sleep = ms => new Promise(r => setTimeout(r, ms));

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

// Everything the chat voice path might be made of, old shape or new; only
// what exists is lifted, and the queue cases fail loudly when the queue
// functions are missing rather than crashing the file.
const NAMES = ['chatSpeakOn', 'renderChatMsg', 'chatReset', 'pollChat',
               'updateChatChrome', 'fetchChatRecord', 'speakChat', 'clipKey',
               'clipFailed', 'dropClipQueue', 'enqueueClip', 'playNextClip'];

function makeCtx(opts) {
	opts = opts || {};
	const els = {};
	const el = id => els[id] || (els[id] = {
		id, textContent: '', value: '', checked: false, hidden: false,
		children: [], scrollTop: 0, scrollHeight: 0,
		appendChild(c) { this.children.push(c); },
		classList: {add() {}, remove() {}, toggle() {},
		            contains() { return false; }},
	});
	el('chat-speak').checked = opts.speak !== false;

	const state = {
		consoleLines: [], fetches: [], audioMade: [], playOrder: [],
		overlaps: 0, active: 0, els,
	};

	const chatResponses = (opts.chatResponses || []).slice();
	const lastEmpty = () => ({game: ctx.chatGame, player: ctx.playerLabel,
	                          name: 'Betty', count: ctx.chatCount,
	                          messages: []});

	class FakeAudio {
		constructor(src) {
			this.src = String(src);
			this.currentTime = 0;
			this._ls = {};
			this.onended = null;
			this.onerror = null;
			state.audioMade.push(this);
		}
		addEventListener(k, f) { (this._ls[k] = this._ls[k] || []).push(f); }
		_fire(k) {
			(this._ls[k] || []).forEach(f => f.call(this));
			if (k === 'ended' && this.onended) this.onended();
			if (k === 'error' && this.onerror) this.onerror();
			if (k === 'ended' || k === 'error') state.active--;
		}
		play() {
			const n = +(this.src.split(':')[1]);
			this.n = n;
			state.playOrder.push(n);
			if (state.active > 0) state.overlaps++;
			state.active++;
			const mode = (opts.clipPlay && opts.clipPlay(n)) || 'end';
			if (mode === 'end') {
				setTimeout(() => { this._fire('playing');
				                   this._fire('ended'); }, 10);
			} else if (mode === 'error') {
				setTimeout(() => this._fire('error'), 10);
			} else if (mode === 'slow') {
				setTimeout(() => this._fire('playing'), 20);
				setTimeout(() => this._fire('ended'), 400);
			}
			// 'silent': play() resolves and nothing ever fires.
			return Promise.resolve();
		}
		pause() { if (state.active > 0) state.active--; }
	}

	const ctx = {
		// page state the lifted functions read and write, via with()
		ws: {readyState: 1}, chatBusy: false, chatGame: null, chatCount: 0,
		chatHistory: true, chatPoll: null, playerLabel: null,
		assistantName: 'Betty',
		clipQueue: [], clipPlaying: false, clipDead: {},
		CLIP_START_GRACE_MS: 150,
		// stubs
		$: el,
		log: line => state.consoleLines.push(String(line)),
		document: {createElement: () => ({
			className: '', textContent: '', style: {}, children: [],
			appendChild(c) { this.children.push(c); },
			setAttribute() {},
			querySelector: () => ({setAttribute() {}}),
		})},
		URL: {createObjectURL: b => 'blob:' + (b && b.n),
		      revokeObjectURL() {}},
		Audio: FakeAudio,
		fetch: url => {
			state.fetches.push(url);
			if (url.startsWith('/chat/audio')) {
				const m = /[?&]n=(\d+)/.exec(url);
				const n = m ? +m[1] : -1;
				const mode = (opts.clipFetch && opts.clipFetch(n)) || 'ok';
				if (mode !== 'ok')
					return Promise.resolve({ok: false, status: 503});
				return Promise.resolve({ok: true,
				                        blob: async () => ({n})});
			}
			if (url.startsWith('/chat?'))
				return Promise.resolve({ok: true, json: async () =>
					chatResponses.length ? chatResponses.shift()
					                     : lastEmpty()});
			if (url.startsWith('/record'))
				return Promise.resolve({ok: true,
				                        json: async () => ({records: []})});
			return Promise.resolve({ok: false, status: 404});
		},
	};
	ctx._state = state;
	return ctx;
}

function build(ctx) {
	const found = NAMES.map(liftOne).filter(Boolean);
	const exported = NAMES.filter(n => liftOne(n) !== null);
	// Non-strict on purpose: `with` is what lets the lifted code read and
	// WRITE the page-level lets (chatCount, clipQueue, ...) as ctx's own.
	return new Function('ctx', 'with (ctx) {\n' + found.join('\n') +
		'\nreturn {' + exported.join(',') + '};\n}')(ctx);
}

const audioFetches = ctx =>
	ctx._state.fetches.filter(u => u.startsWith('/chat/audio'));
const fetchedNs = ctx =>
	audioFetches(ctx).map(u => +(/[?&]n=(\d+)/.exec(u) || [0, -1])[1]);

// A game switch, then a silent history batch, so the thread is live and the
// next batch is new arrivals — the shape every case below starts from.
async function primeThread(api, ctx, history) {
	await api.pollChat();  // game switch: reset, thread refetches from 0
	await api.pollChat();  // the history batch: rendered, never voiced
	if (ctx.chatGame !== 'g-1') bad('priming: the game never loaded',
	                               ctx.chatGame);
	if (ctx.chatHistory !== false) bad('priming: history never cleared',
	                                   ctx.chatHistory);
}

// --- 1: every message of hers is voiced, in order, one at a time -----------

async function testAllVoiced() {
	console.log('two of her messages in one batch: both voiced, in order, '
	            + 'sequentially:');
	const hist = {game: 'g-1', player: 'Visitor', name: 'Betty', count: 1,
	              messages: [{who: 'assistant', text: 'old line'}]};
	const ctx = makeCtx({chatResponses: [
		hist, hist,
		{game: 'g-1', player: 'Visitor', name: 'Betty', count: 3,
		 messages: [{who: 'assistant', text: 'one'},
		            {who: 'assistant', text: 'two'}]},
	]});
	const api = build(ctx);
	await primeThread(api, ctx);
	if (audioFetches(ctx).length === 0)
		ok('the page-load backlog was rendered and never voiced');
	else
		bad('history must never autoplay', audioFetches(ctx).join(' '));
	await api.pollChat();
	await sleep(120);
	const ns = fetchedNs(ctx);
	if (ns.includes(1) && ns.includes(2))
		ok('both arriving messages were fetched as clips (indices 1 and 2)');
	else
		bad('every her-message arriving while the toggle is on gets its clip '
		    + '— not one per batch', 'fetched n=' + ns.join(','));
	const played = ctx._state.playOrder;
	if (played.length === 2 && played[0] === 1 && played[1] === 2)
		ok('and they sounded in arrival order');
	else
		bad('clips must sound in arrival order', played.join(','));
	if (ctx._state.overlaps === 0)
		ok('one at a time: no two clips ever sounded together');
	else
		bad('clips must be serialised, never overlapped',
		    ctx._state.overlaps + ' overlap(s)');
}

// --- 2: a dead clip is a console witness, and the queue advances -----------

async function testDeadClipAdvances() {
	console.log('');
	console.log('a clip that cannot be fetched: witnessed, and the next one '
	            + 'still sounds:');
	const hist = {game: 'g-1', player: null, name: 'Betty', count: 0,
	              messages: []};
	const ctx = makeCtx({
		chatResponses: [hist, hist,
			{game: 'g-1', player: null, name: 'Betty', count: 2,
			 messages: [{who: 'assistant', text: 'a'},
			            {who: 'assistant', text: 'b'}]}],
		clipFetch: n => (n === 0 ? 'http503' : 'ok'),
	});
	const api = build(ctx);
	await primeThread(api, ctx);
	await api.pollChat();
	await sleep(120);
	if (ctx._state.consoleLines.some(l => /Her voice is unavailable/.test(l)))
		ok('the failure is named in the page console, text kept');
	else
		bad('a lost clip must say so in the console',
		    ctx._state.consoleLines.join(' | ') || 'nothing');
	if (ctx._state.playOrder.includes(1))
		ok('the clip behind the dead one still sounded');
	else
		bad('one dead clip must not park the thread\'s voice',
		    'played n=' + ctx._state.playOrder.join(','));
}

// --- 3: a clip that never starts is given up on within the bound -----------

async function testNeverStartsGivesUp() {
	console.log('');
	console.log('a clip that never begins to sound: given up on, queue '
	            + 'freed:');
	const hist = {game: 'g-1', player: null, name: 'Betty', count: 0,
	              messages: []};
	const ctx = makeCtx({
		chatResponses: [hist, hist,
			{game: 'g-1', player: null, name: 'Betty', count: 2,
			 messages: [{who: 'assistant', text: 'a'},
			            {who: 'assistant', text: 'b'}]}],
		clipPlay: n => (n === 0 ? 'silent' : 'end'),
	});
	const api = build(ctx);
	await primeThread(api, ctx);
	await api.pollChat();
	await sleep(400);  // the harness grace is 150ms
	if (ctx._state.consoleLines.some(l => /Her voice is unavailable/.test(l)))
		ok('the give-up is witnessed in the console');
	else
		bad('a clip that never starts must be given up on out loud',
		    ctx._state.consoleLines.join(' | ') || 'nothing');
	if (ctx._state.playOrder.includes(1))
		ok('and the clip behind it still sounded');
	else
		bad('the queue must advance past a clip that never starts',
		    'played n=' + ctx._state.playOrder.join(','));
}

// --- 3b: the bound never cuts a clip that is sounding ----------------------

async function testSlowClipNotCut() {
	console.log('');
	console.log('a clip still sounding past the bound is never cut:');
	const hist = {game: 'g-1', player: null, name: 'Betty', count: 0,
	              messages: []};
	const ctx = makeCtx({
		chatResponses: [hist, hist,
			{game: 'g-1', player: null, name: 'Betty', count: 2,
			 messages: [{who: 'assistant', text: 'a'},
			            {who: 'assistant', text: 'b'}]}],
		clipPlay: n => (n === 0 ? 'slow' : 'end'),  // sounds at 20ms, ends 400
	});
	const api = build(ctx);
	await primeThread(api, ctx);
	await api.pollChat();
	await sleep(650);
	if (!ctx._state.consoleLines.some(l =>
			/Her voice is unavailable/.test(l)))
		ok('no failure was invented for a clip that was sounding');
	else
		bad('a sounding clip must never be reported failed',
		    ctx._state.consoleLines.join(' | '));
	const played = ctx._state.playOrder;
	if (played.length === 2 && played[0] === 0 && played[1] === 1
			&& ctx._state.overlaps === 0)
		ok('it played out whole, then the next clip took its turn');
	else
		bad('the slow clip plays out and the queue follows it',
		    'played n=' + played.join(',') + ' overlaps='
		    + ctx._state.overlaps);
}

// --- 4: the toggle and the roles ------------------------------------------

async function testToggleAndRoles() {
	console.log('');
	console.log('the toggle is honoured and only her messages are voiced:');
	const hist = {game: 'g-1', player: 'Visitor', name: 'Betty', count: 0,
	              messages: []};
	const off = makeCtx({speak: false, chatResponses: [hist, hist,
		{game: 'g-1', player: 'Visitor', name: 'Betty', count: 1,
		 messages: [{who: 'assistant', text: 'quiet room'}]}]});
	const apiOff = build(off);
	await primeThread(apiOff, off);
	await apiOff.pollChat();
	await sleep(60);
	if (audioFetches(off).length === 0)
		ok('toggle off: nothing is fetched, nothing sounds');
	else
		bad('toggle off must mean no clips at all',
		    audioFetches(off).join(' '));

	const mixed = makeCtx({chatResponses: [hist, hist,
		{game: 'g-1', player: 'Visitor', name: 'Betty', count: 3,
		 messages: [{who: 'player', text: 'mine'},
		            {who: 'assistant', text: 'hers'},
		            {who: 'system', text: 'forged'}]}]});
	const apiMix = build(mixed);
	await primeThread(apiMix, mixed);
	await apiMix.pollChat();
	await sleep(60);
	const ns = fetchedNs(mixed);
	if (ns.length === 1 && ns[0] === 1)
		ok('only the assistant-role index was fetched — never the sitter\'s '
		   + 'line, never a forged role');
	else
		bad('only role assistant may reach the voice', 'n=' + ns.join(','));
}

// --- 5: a reset empties the queue; the refetched thread is history ---------

async function testResetDropsQueue() {
	console.log('');
	console.log('a game switch empties the queue and refetches silently:');
	const hist = {game: 'g-1', player: null, name: 'Betty', count: 0,
	              messages: []};
	const ctx = makeCtx({
		chatResponses: [hist, hist,
			{game: 'g-1', player: null, name: 'Betty', count: 3,
			 messages: [{who: 'assistant', text: 'a'},
			            {who: 'assistant', text: 'b'},
			            {who: 'assistant', text: 'c'}]},
			{game: 'g-2', player: null, name: 'Betty', count: 2,
			 messages: []},
			{game: 'g-2', player: null, name: 'Betty', count: 2,
			 messages: [{who: 'assistant', text: 'x'},
			            {who: 'assistant', text: 'y'}]}],
		clipPlay: n => (n === 0 ? 'slow' : 'end'),  // holds the queue busy
	});
	const api = build(ctx);
	await primeThread(api, ctx);
	await api.pollChat();     // three clips: 0 playing slow, 1 and 2 queued
	await sleep(60);
	await api.pollChat();     // g-2 arrives: reset, queue must empty
	await api.pollChat();     // g-2's backlog: history, silent
	await sleep(700);
	const ns = fetchedNs(ctx);
	if (!ns.includes(1) && !ns.includes(2))
		ok('the old game\'s queued clips were dropped with its thread');
	else
		bad('a reset must empty the clip queue', 'fetched n=' + ns.join(','));
	if (audioFetches(ctx).length <= 1)
		ok('the new game\'s backlog rendered without a sound');
	else
		bad('a refetched thread is history and must not autoplay',
		    audioFetches(ctx).join(' '));
}

// --- 6: a failed clip is failed for good ----------------------------------

async function testDeadForGood() {
	console.log('');
	console.log('a failed clip is dead for good — never refetched:');
	const ctx = makeCtx({clipFetch: () => 'http503'});
	const api = build(ctx);
	if (!api.enqueueClip || !api.dropClipQueue) {
		bad('the clip queue API (enqueueClip/dropClipQueue) does not exist '
		    + 'in board.js', 'missing');
		return;
	}
	ctx.chatGame = 'g-1';
	api.enqueueClip('g-1', 0);
	await sleep(60);
	const first = audioFetches(ctx).length;
	api.enqueueClip('g-1', 0);
	await sleep(60);
	if (first === 1 && audioFetches(ctx).length === 1)
		ok('the dead index was never asked for twice');
	else
		bad('a dead clip must never be refetched',
		    audioFetches(ctx).length + ' fetch(es)');
}

(async () => {
	await testAllVoiced();
	await testDeadClipAdvances();
	await testNeverStartsGivesUp();
	await testSlowClipNotCut();
	await testToggleAndRoles();
	await testResetDropsQueue();
	await testDeadForGood();
	console.log('');
	console.log('chess client chat voice: ' + PASS + ' passed, '
	            + FAIL + ' failed');
	process.exit(FAIL ? 1 : 0);
})();
