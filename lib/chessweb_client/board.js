// The shipped chessweb client (specs/chessweb.md — THE SHIPPED CLIENT).
//
// It speaks the stock SpeedyChess wire over one binary WebSocket: out are
// one-byte-length frames and a bare-byte Ping, in are uvarint-length frames
// and a bare-byte Ping. The board here is echo-driven: nothing the user does
// changes game state until the server broadcasts it back, so what is on
// screen is always what the store holds — a dragged piece may rest on its
// target while the send is in flight, but a server Error (or three quiet
// seconds) slides it home. Legality for highlighting and snap-back comes
// from GET /state (rule 18); this file owns no chess rules at all.
'use strict';

// Message type = the message's index in SpeedyChess's chesspb.proto.
const MT = {PING: 0, JOIN: 1, NEWGAME: 2, MOVE: 3, ERROR: 4, TEAM: 5,
            PLAYER: 6, OPPONENT_LEFT: 7, OPPONENT_JOINED: 8, PROMOTE: 9,
            GAME_COMPLETE: 10};
const REGULAR = 0, EN_PASSANT = 1, CASTLE_LEFT = 2, CASTLE_RIGHT = 3;

const VAL = {P: 1, N: 3, B: 3, R: 5, Q: 9, K: 0};
const FILES = 'abcdefgh';
// Promotion answers travel as the rune of the piece glyph, in the seat's own
// colour; a broadcast Promote carries the same rune back to everyone.
const PROMO_CHOICES = [
	{t: 'Q', w: 0x2655, b: 0x265B}, {t: 'R', w: 0x2656, b: 0x265C},
	{t: 'B', w: 0x2657, b: 0x265D}, {t: 'N', w: 0x2658, b: 0x265E}];
const RUNE_PIECE = {0x2655: 'Q', 0x2656: 'R', 0x2657: 'B', 0x2658: 'N',
                    0x265B: 'Q', 0x265C: 'R', 0x265D: 'B', 0x265E: 'N'};

// ---------------------------------------------------------------- state
let ws = null;             // the one connection
let rxbuf = [];            // bytes not yet parsed into protocol messages
let seated = false;        // Player received; we hold the seat
let black = false;         // Team said we play black; flips the view
let gameOver = false;
let ply = 0;               // moves applied since the last Team
let pieces = [];           // {t,w,x,y,alive,el} in wire coords (y0 = black's back rank)
let grave = {w: [], b: []};// pieces captured BY white / BY black
let legal = null;          // last /state whose ply matched ours
let selected = null;       // click-to-move origin {x,y}
let drag = null;           // live drag {p,ox,oy,moved,startX,startY}
let pendingSend = null;    // a dragged move awaiting its echo {p,tx,ty,timer}
let promoPending = null;   // Promote prompt awaiting our pick {x,y}
let lastMove = null;       // {f:[x,y], t:[x,y]} for the tint
let squares = [];          // 64 square divs, wire order y*8+x
let stateTimer = null, statePoll = null, stateRetries = 0;
let gameId = null;         // last game id /state reported, for the resign guard
let resignArm = null;      // the armed Resign button's fall-back timer
let clockState = null;     // /state's clock photograph {w, b, running, at, over}

// The table chat (specs/chessweb.md rule 24): the thread is polled off
// GET /chat with a cursor; the first batch for a game is history and is
// rendered silently — the speak toggle voices only what arrives after it,
// each message as a clip of HER OWN voice off GET /chat/audio (rule 24e).
let chatGame = null;       // the game the chat panel is showing
let chatCount = 0;         // messages already rendered (the ?since cursor)
let chatHistory = true;    // the next batch is a page-load backlog
let chatPoll = null;
let chatBusy = false;
let playerLabel = null;    // /chat's player — the LOADED game's own label
let assistantName = 'The assistant';

const $ = id => document.getElementById(id);
const boardEl = () => $('board');

// ---------------------------------------------------------------- console
function log(msg) {
	const el = $('console');
	el.textContent = (msg + '\n' + el.textContent).split('\n')
		.slice(0, 250).join('\n');
}

// ---------------------------------------------------------------- wire
function enc(pairs) { // varint fields only; proto3 omits zeros
	const out = [];
	for (const [num, val] of pairs) {
		if (!val) continue;
		out.push(num << 3);
		let v = val;
		for (;;) {
			const b = v & 0x7F;
			v >>= 7;
			if (v) out.push(b | 0x80); else { out.push(b); break; }
		}
	}
	return out;
}

function sendMsg(type, payload = []) {
	if (!ws || ws.readyState !== 1) return;
	ws.send(new Uint8Array([type, payload.length].concat(payload)));
}

function sendPing() {
	if (ws && ws.readyState === 1) ws.send(new Uint8Array([MT.PING]));
}

function fieldsOf(bytes) {
	const f = {};
	let i = 0;
	while (i < bytes.length) {
		const tag = bytes[i++], num = tag >> 3, wt = tag & 7;
		if (wt === 0) {
			let v = 0, s = 0;
			for (;;) {
				const b = bytes[i++];
				v |= (b & 0x7F) << s;
				if (!(b & 0x80)) break;
				s += 7;
			}
			f[num] = v;
		} else if (wt === 2) {
			const n = bytes[i++];
			f[num] = bytes.slice(i, i + n);
			i += n;
		} else {
			return f; // nothing in this protocol reaches here
		}
	}
	return f;
}

function drain() {
	for (;;) {
		if (!rxbuf.length) return;
		if (rxbuf[0] === MT.PING) { // bare byte, no length
			rxbuf.shift();
			sendPing();
			continue;
		}
		let i = 1, shift = 0, len = 0, whole = false;
		while (i < rxbuf.length) {
			const b = rxbuf[i++];
			len |= (b & 0x7F) << shift;
			if (!(b & 0x80)) { whole = true; break; }
			shift += 7;
		}
		if (!whole || rxbuf.length < i + len) return;
		const type = rxbuf[0], payload = rxbuf.slice(i, i + len);
		rxbuf.splice(0, i + len);
		handle(type, fieldsOf(payload));
	}
}

// ---------------------------------------------------------------- board DOM
function buildSquares() {
	const bd = boardEl();
	squares = [];
	for (let y = 0; y < 8; y++) {
		for (let x = 0; x < 8; x++) {
			const sq = document.createElement('div');
			sq.className = 'square' + ((x + y) % 2 ? ' darksq' : '');
			sq.dataset.x = x;
			sq.dataset.y = y;
			bd.appendChild(sq);
			squares.push(sq);
		}
	}
	layoutSquares();
}

function disp(x, y) { // wire -> display cell, honouring orientation
	return black ? [7 - x, 7 - y] : [x, y];
}

function layoutSquares() {
	for (const sq of squares) {
		const x = +sq.dataset.x, y = +sq.dataset.y;
		const [dx, dy] = disp(x, y);
		sq.style.left = dx * 12.5 + '%';
		sq.style.top = dy * 12.5 + '%';
		if (dy === 7) sq.dataset.file = FILES[x]; else delete sq.dataset.file;
		if (dx === 0) sq.dataset.rank = 8 - y; else delete sq.dataset.rank;
	}
}

function squareAt(x, y) { return squares[y * 8 + x]; }

function initialPieces() {
	const back = ['R', 'N', 'B', 'Q', 'K', 'B', 'N', 'R'];
	const out = [];
	for (let x = 0; x < 8; x++) {
		out.push({t: back[x], w: false, x, y: 0, alive: true, el: null});
		out.push({t: 'P', w: false, x, y: 1, alive: true, el: null});
		out.push({t: 'P', w: true, x, y: 6, alive: true, el: null});
		out.push({t: back[x], w: true, x, y: 7, alive: true, el: null});
	}
	return out;
}

function pieceEl(p) {
	const el = document.createElement('div');
	el.className = 'piece ' + (p.w ? 'w' : 'b');
	el.innerHTML = `<svg viewBox="0 0 45 45"><use href="#pc-${p.t}"/></svg>`;
	return el;
}

function position(p) {
	const [dx, dy] = disp(p.x, p.y);
	p.el.style.transform = `translate(${dx * 100}%, ${dy * 100}%)`;
}

function resetBoard() {
	for (const p of pieces) if (p.el) p.el.remove();
	pieces = initialPieces();
	grave = {w: [], b: []};
	ply = 0;
	gameOver = false;
	selected = null;
	drag = null;
	promoPending = null;
	$('promo').hidden = true;
	$('banner').hidden = true;
	if (pendingSend) { clearTimeout(pendingSend.timer); pendingSend = null; }
	lastMove = null;
	legal = null;
	layoutSquares();
	clearMarks();
	const bd = boardEl();
	for (const p of pieces) {
		p.el = pieceEl(p);
		bd.appendChild(p.el);
		position(p);
	}
	renderGraves();
}

function pieceOn(x, y) {
	return pieces.find(p => p.alive && p.x === x && p.y === y) || null;
}

// ---------------------------------------------------------------- marks
function clearMarks() {
	for (const sq of squares) sq.classList.remove('sel', 'hint', 'cap');
}

function markLast() {
	for (const sq of squares) sq.classList.remove('last');
	if (!lastMove) return;
	squareAt(...lastMove.f).classList.add('last');
	squareAt(...lastMove.t).classList.add('last');
}

function markCheck(st) {
	for (const sq of squares) sq.classList.remove('check');
	if (!st || st.state !== 'active' || !/check/.test(st.desc || '')) return;
	const king = pieces.find(
		p => p.alive && p.t === 'K' && p.w === (st.turn === 'white'));
	if (king) squareAt(king.x, king.y).classList.add('check');
}

function refuse(x, y) {
	const sq = squareAt(x, y);
	sq.classList.remove('refuse');
	void sq.offsetWidth; // restart the animation
	sq.classList.add('refuse');
}

// ---------------------------------------------------------------- graveyards
function renderGraves() {
	for (const side of ['w', 'b']) {
		const list = grave[side].slice()
			.sort((a, b) => VAL[b.t] - VAL[a.t]);
		$(`gy-${side}-list`).innerHTML = list.map(p =>
			`<span class="tomb ${p.w ? 'w' : 'b'}">` +
			`<svg viewBox="0 0 45 45"><use href="#pc-${p.t}"/></svg></span>`
		).join('');
		const pts = list.reduce((n, p) => n + VAL[p.t], 0);
		$(`gy-${side}-score`).textContent =
			pts + ' point' + (pts === 1 ? '' : 's');
	}
	// The differential comes off the live board, not the graveyards, so a
	// promotion re-values it correctly.
	let diff = 0;
	for (const p of pieces) if (p.alive) diff += p.w ? VAL[p.t] : -VAL[p.t];
	$('gy-w-badge').hidden = diff <= 0;
	$('gy-b-badge').hidden = diff >= 0;
	if (diff > 0) $('gy-w-badge').textContent = '+' + diff;
	if (diff < 0) $('gy-b-badge').textContent = '+' + (-diff);
}

function kill(victim, byWhite) {
	victim.alive = false;
	grave[byWhite ? 'w' : 'b'].push({t: victim.t, w: victim.w});
	const el = victim.el;
	victim.el = null;
	el.classList.add('dying');
	setTimeout(() => el.remove(), 320);
	renderGraves();
}

// ---------------------------------------------------------------- turns
function whiteToMove() { return ply % 2 === 0; }

function myTurn() {
	return seated && !gameOver && (black ? !whiteToMove() : whiteToMove());
}

function updateTurnline(st) {
	const el = $('turnline');
	if (!ws || ws.readyState !== 1) { el.textContent = ''; return; }
	if (st && st.game === null) {
		el.textContent = seated ? 'No game yet — New Game starts one.' : '';
		return;
	}
	if (st && st.state && st.state !== 'active') {
		el.textContent = st.desc + '  [' + st.result + ']';
		return;
	}
	if (st && st.desc) {
		el.textContent = (myTurn() ? 'Your move — ' : '') + st.desc;
		return;
	}
	el.textContent = myTurn() ? 'Your move'
		: (whiteToMove() ? 'White' : 'Black') + ' to move';
}

// ---------------------------------------------------------------- clocks
// specs/chessweb.md rule 22f: /state carries the live clock; this file only
// PAINTS it — counting down locally between polls — and never judges a flag.
// The server records the fall and says so through GameComplete and desc.
function updateClocks(st) {
	const ck = st && st.clock;
	if (!ck) {
		clockState = null;
	} else {
		clockState = {w: ck.white_ms, b: ck.black_ms, running: ck.running,
		              at: Date.now(), over: st.state !== 'active'};
	}
	renderClocks();
}

function fmtClock(ms) {
	if (ms < 20000) return (ms / 1000).toFixed(1); // tenths when it matters
	const t = Math.floor(ms / 1000);
	return Math.floor(t / 60) + ':' + String(t % 60).padStart(2, '0');
}

function renderClocks() {
	for (const side of ['w', 'b']) {
		const el = $('clock-' + side);
		if (!el) continue;
		if (!clockState) { el.hidden = true; continue; }
		let ms = clockState[side];
		const run = !clockState.over
			&& clockState.running === (side === 'w' ? 'white' : 'black');
		if (run) ms -= Date.now() - clockState.at;
		ms = Math.max(0, ms);
		el.hidden = false;
		el.textContent = fmtClock(ms);
		el.classList.toggle('running', run);
		el.classList.toggle('low', ms < 30000);
		el.classList.toggle('flagged', ms <= 0);
	}
}

// ---------------------------------------------------------------- /state
function scheduleState(delay = 120) {
	clearTimeout(stateTimer);
	stateTimer = setTimeout(fetchState, delay);
}

async function fetchState() {
	let st;
	try {
		const r = await fetch('/state', {cache: 'no-store'});
		st = await r.json();
	} catch (e) {
		return; // opened from file://, or the bridge is gone; play blind
	}
	if (st.game === null) {
		legal = null;
		gameId = null;
		updateClocks(st);
		updateResign(st);
		updateTurnline(st);
		return;
	}
	gameId = st.game;
	// Before the ply gate: the clocks are true whatever the replay is doing.
	updateClocks(st);
	updateResign(st);
	if (st.ply !== ply) {
		// The photograph and the board disagree — a replay is mid-flight or
		// a move is still being recorded. Ask again shortly, bounded.
		legal = null;
		if (stateRetries++ < 8) scheduleState(300);
		return;
	}
	stateRetries = 0;
	for (const m of st.legal || []) {
		m.fx = FILES.indexOf(m.from[0]); m.fy = 8 - +m.from[1];
		m.tx = FILES.indexOf(m.to[0]);   m.ty = 8 - +m.to[1];
	}
	legal = st;
	updateTurnline(st);
	markCheck(st);
	if (st.state !== 'active' && !gameOver) {
		// e.g. a resignation recorded on disk; GameComplete also arrives,
		// but the words here are better than the protocol's three results.
		showBanner(st.desc);
	}
}

// ---------------------------------------------------------------- moves in
function clearPendingFor(p, tx, ty) {
	if (!pendingSend) return;
	clearTimeout(pendingSend.timer);
	const match = pendingSend.p === p
		&& pendingSend.tx === tx && pendingSend.ty === ty;
	if (!match && pendingSend.p.el) position(pendingSend.p);
	pendingSend = null;
}

function applyWireMove(fx, fy, tx, ty, mtype) {
	const p = pieceOn(fx, fy);
	if (!p) { log('Board out of step — rejoin to resync.'); return; }
	let dest = {x: tx, y: ty};
	if (mtype === EN_PASSANT) {
		// The wire's "to" is the captured pawn's square; the mover lands on
		// that file, one rank onward.
		const victim = pieceOn(tx, ty);
		if (victim) kill(victim, p.w);
		dest = {x: tx, y: fy + (p.w ? -1 : 1)};
	} else if (mtype === CASTLE_LEFT || mtype === CASTLE_RIGHT) {
		const left = mtype === CASTLE_LEFT;
		const rook = pieceOn(left ? 0 : 7, fy);
		dest = {x: left ? 2 : 6, y: fy};
		if (rook) {
			rook.x = left ? 3 : 5;
			rook.y = fy;
			position(rook);
		}
	} else {
		const victim = pieceOn(tx, ty);
		if (victim && victim !== p) kill(victim, p.w);
	}
	clearPendingFor(p, dest.x, dest.y);
	p.x = dest.x;
	p.y = dest.y;
	p.el.classList.remove('lift');
	position(p);
	lastMove = {f: [fx, fy], t: [dest.x, dest.y]};
	markLast();
	ply++;
	clearSelection();
	updateTurnline(null);
	scheduleState();
}

function applyPromotion(x, y, rune) {
	const p = pieceOn(x, y);
	const t = RUNE_PIECE[rune];
	if (p && t) {
		p.t = t;
		p.el.querySelector('use').setAttribute('href', '#pc-' + t);
	}
	promoPending = null;
	$('promo').hidden = true;
	renderGraves();
	scheduleState();
}

function promptPromotion(x, y) {
	promoPending = {x, y};
	const side = black ? 'b' : 'w';
	$('promo-choices').innerHTML = PROMO_CHOICES.map(c =>
		`<button type="button" class="${side}" data-rune="${c[side]}">` +
		`<svg viewBox="0 0 45 45"><use href="#pc-${c.t}"/></svg></button>`
	).join('');
	for (const b of $('promo-choices').querySelectorAll('button')) {
		b.onclick = () => {
			if (!promoPending) return;
			sendMsg(MT.PROMOTE, enc([[1, promoPending.x],
			                         [2, promoPending.y],
			                         [3, +b.dataset.rune]]));
			$('promo').hidden = true;
		};
	}
	$('promo').hidden = false;
}

function showBanner(text) {
	$('banner').innerHTML = '';
	const card = document.createElement('div');
	card.className = 'banner-card';
	card.textContent = text;
	$('banner').appendChild(card);
	$('banner').hidden = false;
	setTimeout(() => { $('banner').hidden = true; }, 6000);
}

// ---------------------------------------------------------------- resign
// The button never fires on one click: the first click arms it (the label
// says so), a second within five seconds sends POST /resign (rule 19), and
// the arm falls back on its own. The finish then arrives like any other
// move — GameComplete off the wire, the words off /state.
function disarmResign() {
	clearTimeout(resignArm);
	resignArm = null;
	const b = $('resign');
	b.textContent = 'Resign';
	b.classList.remove('armed');
}

function updateResign(st) {
	const on = seated && !gameOver
		&& !!(st && st.game && st.state === 'active');
	$('resign').disabled = !on;
	if (!on && resignArm) disarmResign();
}

async function resignClick() {
	if (!resignArm) {
		const b = $('resign');
		b.textContent = 'Sure? Click again';
		b.classList.add('armed');
		resignArm = setTimeout(disarmResign, 5000);
		return;
	}
	disarmResign();
	let r, j;
	try {
		r = await fetch('/resign', {method: 'POST',
			headers: {'Content-Type': 'application/json'},
			body: JSON.stringify({game: gameId})});
		j = await r.json();
	} catch (e) {
		log('Resign failed: ' + e.message);
		return;
	}
	if (j.error) log('Server: ' + j.error);
	else log('You resigned — ' + j.desc + '  [' + j.result + '].');
	scheduleState();
}

// ---------------------------------------------------------------- protocol in
function handle(type, f) {
	switch (type) {
	case MT.TEAM:
		black = !!f[1];
		seated && log('You play ' + (black ? 'black.' : 'white.'));
		resetBoard();
		updateTurnline(null);
		scheduleState();
		break;
	case MT.MOVE:
		applyWireMove(f[1] || 0, f[2] || 0, f[3] || 0, f[4] || 0, f[5] || 0);
		break;
	case MT.PROMOTE:
		if (f[3] !== undefined) applyPromotion(f[1] || 0, f[2] || 0, f[3]);
		else promptPromotion(f[1] || 0, f[2] || 0);
		break;
	case MT.PLAYER:
		seated = true;
		$('join').disabled = true;
		$('watch').disabled = true;
		log('Seated as player ' + ((f[1] || 0) === 1 ? '1.' : '2.'));
		break;
	case MT.OPPONENT_JOINED:
		$('newgame').disabled = false;
		log('Opponent is here — the game is ready.');
		break;
	case MT.OPPONENT_LEFT:
		log('Opponent left.');
		break;
	case MT.GAME_COMPLETE: {
		gameOver = true;
		updateResign(null);
		const text = (f[1] || 0) === 2 ? 'White wins.'
			: (f[1] || 0) === 1 ? 'Black wins.' : 'Drawn.';
		log('Game complete! ' + text);
		showBanner('Game complete — ' + text);
		if (pendingSend) snapBack();
		scheduleState();
		fetchChatRecord(); // the score just changed
		break;
	}
	case MT.ERROR: {
		const msg = new TextDecoder().decode(new Uint8Array(f[1] || []));
		log('Server: ' + msg);
		if (pendingSend) snapBack();
		break;
	}
	}
}

// ---------------------------------------------------------------- moves out
function snapBack() {
	if (!pendingSend) return;
	clearTimeout(pendingSend.timer);
	const p = pendingSend.p;
	pendingSend = null;
	if (p.el) {
		p.el.classList.remove('drag', 'lift');
		position(p);
		refuse(p.x, p.y);
	}
}

function legalFresh() { return legal !== null && legal.ply === ply; }

function movesFrom(x, y) {
	if (!legalFresh()) return null;
	return legal.legal.filter(m => m.fx === x && m.fy === y);
}

function tryMove(p, tx, ty, viaDrag) {
	if (!myTurn() || promoPending) return false;
	const from = movesFrom(p.x, p.y);
	if (from && !from.some(m => m.tx === tx && m.ty === ty)) {
		refuse(tx, ty);
		return false;
	}
	// Plain from/to always suffices: the bridge re-derives castling and en
	// passant from the position (rule 5), so no wire-type mapping out.
	sendMsg(MT.MOVE, enc([[1, p.x], [2, p.y], [3, tx], [4, ty]]));
	if (viaDrag) {
		const [dx, dy] = disp(tx, ty);
		p.el.style.transform = `translate(${dx * 100}%, ${dy * 100}%)`;
		pendingSend = {p, tx, ty, timer: setTimeout(snapBack, 3000)};
	}
	return true;
}

// ---------------------------------------------------------------- selection
function clearSelection() {
	selected = null;
	clearMarks();
	markLast();
}

function select(x, y) {
	clearMarks();
	markLast();
	selected = {x, y};
	squareAt(x, y).classList.add('sel');
	const from = movesFrom(x, y);
	if (!from) return; // stale legality: pickup allowed, the server judges
	for (const m of from) {
		const sq = squareAt(m.tx, m.ty);
		sq.classList.add(
			pieceOn(m.tx, m.ty) || m.type === EN_PASSANT ? 'cap' : 'hint');
	}
}

// ---------------------------------------------------------------- pointer
function squareFromEvent(e) {
	const rect = boardEl().getBoundingClientRect();
	const fx = (e.clientX - rect.left) / rect.width;
	const fy = (e.clientY - rect.top) / rect.height;
	if (fx < 0 || fx >= 1 || fy < 0 || fy >= 1) return null;
	const dx = Math.floor(fx * 8), dy = Math.floor(fy * 8);
	return black ? {x: 7 - dx, y: 7 - dy} : {x: dx, y: dy};
}

function dragTo(e) {
	const rect = boardEl().getBoundingClientRect();
	const size = rect.width / 8;
	const px = Math.max(0, Math.min(rect.width - size,
		e.clientX - rect.left - size / 2));
	const py = Math.max(0, Math.min(rect.height - size,
		e.clientY - rect.top - size / 2));
	drag.p.el.style.transform = `translate(${px}px, ${py}px)`;
}

function onDown(e) {
	if (e.button !== undefined && e.button !== 0) return;
	const hit = squareFromEvent(e);
	if (!hit) return;
	const p = pieceOn(hit.x, hit.y);
	const mine = p && seated && (p.w !== black);
	if (selected && !(selected.x === hit.x && selected.y === hit.y)) {
		if (mine) {
			// clicking another of our pieces re-selects rather than moves
		} else {
			const from = pieceOn(selected.x, selected.y);
			if (from) tryMove(from, hit.x, hit.y, false);
			clearSelection();
			return;
		}
	}
	if (mine && myTurn() && !promoPending && !gameOver) {
		e.preventDefault();
		select(hit.x, hit.y);
		drag = {p, ox: hit.x, oy: hit.y, moved: false,
		        startX: e.clientX, startY: e.clientY};
		p.el.classList.add('lift');
		boardEl().setPointerCapture(e.pointerId);
	} else if (!mine) {
		clearSelection();
	}
}

function onMove(e) {
	if (!drag) return;
	if (!drag.moved) {
		const dist = Math.hypot(e.clientX - drag.startX,
		                        e.clientY - drag.startY);
		if (dist < 5) return;
		drag.moved = true;
		drag.p.el.classList.add('drag');
	}
	dragTo(e);
}

function onUp(e) {
	if (!drag) return;
	const d = drag;
	drag = null;
	d.p.el.classList.remove('drag');
	if (!d.moved) {
		// a plain click: stay selected, piece stays put
		d.p.el.classList.remove('lift');
		position(d.p);
		return;
	}
	const hit = squareFromEvent(e);
	const sent = hit && !(hit.x === d.ox && hit.y === d.oy)
		&& tryMove(d.p, hit.x, hit.y, true);
	if (!sent) {
		d.p.el.classList.remove('lift');
		position(d.p); // the CSS transition slides it home
	}
	clearSelection();
}

function onCancel() {
	if (!drag) return;
	drag.p.el.classList.remove('drag', 'lift');
	position(drag.p);
	drag = null;
	clearSelection();
}

// ---------------------------------------------------------------- connection
function setConnected(on) {
	$('connstate').classList.toggle('on', on);
	$('connect').disabled = on;
	$('join').disabled = !on;
	$('watch').disabled = !on;
	if (!on) {
		$('newgame').disabled = true;
		$('resign').disabled = true;
		disarmResign();
		seated = false;
		clearInterval(statePoll);
		statePoll = null;
		clearInterval(chatPoll);
		chatPoll = null;
		updateTurnline(null);
	} else if (!chatPoll) {
		chatPoll = setInterval(pollChat, 2500);
		pollChat();
	}
}

function connect() {
	if (ws) { ws.onclose = null; ws.close(); ws = null; }
	rxbuf = [];
	const addr = $('serveraddr').value.trim();
	log('Connecting to ' + addr + ' ...');
	try {
		ws = new WebSocket('ws://' + addr);
	} catch (e) {
		log('Bad server address: ' + e.message);
		return;
	}
	ws.binaryType = 'arraybuffer';
	ws.onopen = () => {
		log('Connected.');
		setConnected(true);
		statePoll = setInterval(fetchState, 3000);
		fetchState();
	};
	ws.onmessage = e => {
		const u = new Uint8Array(e.data);
		for (const b of u) rxbuf.push(b);
		drain();
	};
	ws.onclose = () => {
		log('Disconnected.');
		setConnected(false);
		ws = null;
	};
	ws.onerror = () => log('Connection trouble.');
}

// ---------------------------------------------------------------- new game
// specs/chessweb.md rule 22h: the seat opens the next game over POST /new,
// carrying the clock picked in the page's own selector — the standard set
// plus untimed, and the server is the only judge of the name. Creation
// comes back through the ordinary sync (Team + replay to every joined
// connection), so nothing here touches the board. Against a bridge without
// the endpoint — or a page opened from file:// — the click falls back to
// the stock wire NewGame, which deals the serve's own default control.
async function newGameClick() {
	const sel = $('timecontrol');
	const control = sel ? sel.value : 'untimed';
	// The sitter's name rides along (rule 23): whatever is in the box,
	// remembered between visits; an empty box deals an unlabeled game.
	const nameEl = $('playername');
	const player = nameEl ? nameEl.value.trim() : '';
	let j;
	try {
		const r = await fetch('/new', {method: 'POST',
			headers: {'Content-Type': 'application/json'},
			body: JSON.stringify({control, player})});
		j = await r.json();
	} catch (e) {
		sendMsg(MT.NEWGAME, []);
		return;
	}
	if (j.error) log('Server: ' + j.error);
	else log('New game ' + j.game + ' (' + (j.control || 'untimed') + ')'
		+ (j.player ? ', playing as ' + j.player + '.' : '.'));
	scheduleState();
}

// ---------------------------------------------------------------- table chat
// specs/chessweb.md rule 24: the thread lives on the game record and is
// polled off GET /chat with a cursor; sends go to POST /chat. The speak
// toggle (rule 24e) voices only HER messages, and only ones that arrive
// while it is on — a page load's backlog renders silently.
function chatSpeakOn() { return !!($('chat-speak') && $('chat-speak').checked); }

function speakChat(n) {
	// Her message `n` on the record, as a clip of her own voice: the
	// bridge synthesizes it through the same piper pipeline every other
	// voice of hers comes from (rule 24e). The browser's built-in speech
	// narrator is NEVER used — not even as a fallback: a generic voice
	// wearing her words is worse than silence, so a clip that cannot be
	// fetched or played keeps the text and says so in the console.
	fetch('/chat/audio?game=' + encodeURIComponent(chatGame || '')
			+ '&n=' + n, {cache: 'no-store'})
		.then(r => {
			if (!r.ok) throw new Error('HTTP ' + r.status);
			return r.blob();
		})
		.then(b => {
			const url = URL.createObjectURL(b);
			const clip = new Audio(url);
			clip.onended = () => URL.revokeObjectURL(url);
			return clip.play();
		})
		.catch(e => log('Her voice is unavailable ('
			+ ((e && e.message) || e) + ') — text only.'));
}

function chatReset() {
	chatCount = 0;
	chatHistory = true;
	$('chat-log').textContent = '';
}

function renderChatMsg(m) {
	const div = document.createElement('div');
	const hers = m.who === 'assistant';
	div.className = 'chat-msg ' + (hers ? 'hers' : 'yours');
	const who = document.createElement('span');
	who.className = 'chat-who';
	who.textContent = hers ? assistantName : (playerLabel || 'You');
	const text = document.createElement('span');
	text.className = 'chat-text';
	text.textContent = m.text;
	div.appendChild(who);
	div.appendChild(text);
	const logEl = $('chat-log');
	logEl.appendChild(div);
	logEl.scrollTop = logEl.scrollHeight;
	return hers;
}

function updateChatChrome() {
	// Whom the LOADED game is against (rule 23a): the record's own label,
	// never the name box's current text — an unlabeled game says so.
	$('chat-vs').textContent =
		playerLabel ? playerLabel + ' v ' + assistantName
		            : (chatGame ? 'unlabeled game' : '');
	if (!playerLabel) $('chat-record').textContent = '';
}

async function fetchChatRecord() {
	// The standing score (rule 23d), shown from the sitter's side of the
	// table — only for a labeled game: no name, no score to pin on anyone.
	if (!playerLabel) { $('chat-record').textContent = ''; return; }
	let j;
	try {
		const r = await fetch('/record', {cache: 'no-store'});
		j = await r.json();
	} catch (e) { return; }
	const slug = s => (s || '').toLowerCase()
		.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
	const b = (j.records || []).find(x => slug(x.player) === slug(playerLabel));
	if (!b) { $('chat-record').textContent = ''; return; }
	// Her wins are the sitter's losses; flip the view for the reader here.
	$('chat-record').textContent = 'score: you ' + b.losses
		+ ' · ' + (j.name || assistantName) + ' ' + b.wins
		+ ' · draws ' + b.draws;
}

async function pollChat() {
	if (!ws || ws.readyState !== 1 || chatBusy) return;
	chatBusy = true;
	let j;
	try {
		const r = await fetch('/chat?since=' + chatCount, {cache: 'no-store'});
		j = await r.json();
	} catch (e) {
		chatBusy = false;
		return;
	}
	chatBusy = false;
	assistantName = j.name || assistantName;
	if (j.game === null) {
		if (chatGame !== null) { chatGame = null; playerLabel = null; chatReset(); }
		updateChatChrome();
		return;
	}
	if (j.game !== chatGame) {
		// A different game is loaded: restart the thread from the top.
		chatGame = j.game;
		playerLabel = j.player || null;
		chatReset();
		updateChatChrome();
		fetchChatRecord();
		return; // the next poll fetches the whole thread with since=0
	}
	playerLabel = j.player || null;
	if (j.count < chatCount) { chatReset(); return; }
	let spoke = false;
	const batch = j.messages || [];
	for (let i = 0; i < batch.length; i++) {
		const hers = renderChatMsg(batch[i]);
		if (hers && !chatHistory && chatSpeakOn() && !spoke) {
			// chatCount still holds the ?since this batch was fetched
			// with, so since+i is the message's index on the record.
			speakChat(chatCount + i);
			spoke = true; // one clip per batch is plenty
		}
	}
	chatCount = j.count;
	chatHistory = false;
	updateChatChrome();
}

async function sendChat(e) {
	e.preventDefault();
	const input = $('chat-input');
	const text = input.value.trim();
	if (!text) return;
	let r, j;
	try {
		r = await fetch('/chat', {method: 'POST',
			headers: {'Content-Type': 'application/json'},
			body: JSON.stringify({text})});
		j = await r.json();
	} catch (err) {
		log('Chat failed: ' + err.message);
		return;
	}
	if (j.error) { log('Server: ' + j.error); return; }
	input.value = '';
	pollChat();
}

// ---------------------------------------------------------------- thinking
// The native form of rule 12's banner: same /thinking poll the injected
// widget does, drawn into the page's own chrome.
let thinking = null;

function paintThinking() {
	const el = $('crab-thinking');
	if (!thinking) { el.hidden = true; return; }
	const s = thinking, now = s.now + (Date.now() - s.at) / 1000;
	const name = s.name || 'The assistant';
	const ago = t => {
		const d = Math.max(0, Math.round(now - t));
		return d < 60 ? d + 's' : Math.floor(d / 60) + 'm ' + (d % 60) + 's';
	};
	let txt = null;
	if (s.stalled) txt = name + ' is stuck — ' + s.stalled;
	else if (s.started_at) {
		txt = name + ' is thinking — ' + ago(s.started_at);
		if (s.attempts > 1) txt += ' (try ' + s.attempts + ')';
	}
	else if (s.poked_at) txt = name + ' was asked to move '
		+ ago(s.poked_at) + ' ago';
	else if (s.played_at && now - s.played_at < 20)
		txt = name + ' played ' + (s.san || 'her move');
	el.textContent = txt || '';
	el.hidden = !txt;
}

function pollThinking() {
	fetch('/thinking', {cache: 'no-store'})
		.then(r => r.json())
		.then(j => { j.at = Date.now(); thinking = j; paintThinking(); })
		.catch(() => {});
}

// ---------------------------------------------------------------- boot
window.addEventListener('DOMContentLoaded', () => {
	buildSquares();
	resetBoard();
	log('Chess client loaded.');
	$('connect').onclick = connect;
	$('join').onclick = () => sendMsg(MT.JOIN, enc([[1, 1]]));
	$('watch').onclick = () => { sendMsg(MT.JOIN, []); log('Watching.'); };
	$('newgame').onclick = newGameClick;
	$('resign').onclick = resignClick;
	// The sitter's name and the speak toggle, remembered between visits
	// (rules 23 and 24e). localStorage may be walled off (private mode);
	// the page then simply forgets between loads.
	try {
		$('playername').value = localStorage.getItem('crab-chess-player') || '';
		$('chat-speak').checked =
			localStorage.getItem('crab-chess-speak') === '1';
	} catch (e) { /* no store, no memory */ }
	$('playername').addEventListener('change', () => {
		try {
			localStorage.setItem('crab-chess-player',
				$('playername').value.trim());
		} catch (e) { /* ditto */ }
	});
	$('chat-speak').addEventListener('change', () => {
		try {
			localStorage.setItem('crab-chess-speak',
				$('chat-speak').checked ? '1' : '0');
		} catch (e) { /* ditto */ }
	});
	$('chat-form').addEventListener('submit', sendChat);
	const bd = boardEl();
	bd.addEventListener('pointerdown', onDown);
	bd.addEventListener('pointermove', onMove);
	bd.addEventListener('pointerup', onUp);
	bd.addEventListener('pointercancel', onCancel);
	setInterval(pollThinking, 2000);
	setInterval(paintThinking, 1000);
	setInterval(renderClocks, 100); // the local countdown between polls
	pollThinking();
});
