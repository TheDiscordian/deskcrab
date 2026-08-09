#!/usr/bin/env python3
"""betty-chessweb: the browser board onto a betty-chess game.

A SpeedyChess-protocol server. It serves the stock SpeedyChess web client over
HTTP and speaks its wire protocol (framed protobuf over WebSocket) on the same
port, so the user plays in a browser while she plays through `betty-chess move`.
The betty-chess game file is the only record: the user's moves are validated and
appended there, moves appended there by any other hand are mirrored into the
browser, and each recorded user move books one event wake carrying the
position. specs/chessweb.md is the contract; run through `betty-chessweb`,
which owns the venv.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import socket
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import chess

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess_cli  # the betty-chess store: build_board, save_game, compute_state
import chess_reflex  # position memory, asked before any wake is booked

# Message type = the message's index in SpeedyChess's chesspb.proto.
PING, JOIN, NEWGAME, MOVE, ERROR, TEAM, PLAYER, \
    OPPONENT_LEFT, OPPONENT_JOINED, PROMOTE, GAME_COMPLETE = range(11)

REGULAR, EN_PASSANT, CASTLE_LEFT, CASTLE_RIGHT = range(4)
RESULT_STALEMATE, RESULT_BLACK_WIN, RESULT_WHITE_WIN = range(3)

# Promotion pieces travel as the rune of the piece glyph.
RUNE_TO_PROMO = {0x2655: chess.QUEEN, 0x2656: chess.ROOK,    # white ♕♖♗♘
                 0x2657: chess.BISHOP, 0x2658: chess.KNIGHT,
                 0x265B: chess.QUEEN, 0x265C: chess.ROOK,    # black ♛♜♝♞
                 0x265D: chess.BISHOP, 0x265E: chess.KNIGHT}
WHITE_PROMO_RUNE = {chess.QUEEN: 0x2655, chess.ROOK: 0x2656,
                    chess.BISHOP: 0x2657, chess.KNIGHT: 0x2658}
BLACK_PROMO_RUNE = {chess.QUEEN: 0x265B, chess.ROOK: 0x265C,
                    chess.BISHOP: 0x265D, chess.KNIGHT: 0x265E}
RUNE_IS_WHITE = {r: True for r in WHITE_PROMO_RUNE.values()}
RUNE_IS_WHITE.update({r: False for r in BLACK_PROMO_RUNE.values()})

CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript",
                 ".css": "text/css", ".wasm": "application/wasm",
                 ".png": "image/png", ".ico": "image/x-icon",
                 ".json": "application/json"}


ASSISTANT_NAME = os.environ.get("ASSISTANT_NAME", "The assistant")

# Injected into the stock client's index.html: a one-line clock over the board
# saying whether she has been asked for a move, whether she has picked the
# thought up, and how long ago. Polls /thinking; touches nothing else on the
# page, so a client rebuild cannot break it.
THINKING_WIDGET = ("""
<div id="crab-thinking" style="position:fixed;top:0;left:0;right:0;z-index:99;
 font:600 15px/1.6 system-ui,sans-serif;text-align:center;padding:4px 8px;
 background:#1c1a24;color:#e8e2f0;display:none"></div>
<script>
(function(){
  var el=document.getElementById('crab-thinking'), s=null;
  function ago(t,now){var d=Math.max(0,Math.round(now-t));
    return d<60?d+'s':Math.floor(d/60)+'m '+(d%%60)+'s';}
  function paint(){
    if(!s){el.style.display='none';return;}
    var now=s.now+(Date.now()-s.at)/1000, txt=null;
    if(s.started_at) txt='%(name)s is thinking \\u2014 '+ago(s.started_at,now);
    else if(s.poked_at) txt='%(name)s was asked to move '
      +ago(s.poked_at,now)+' ago';
    else if(s.played_at&&now-s.played_at<20)
      txt='%(name)s played '+(s.san||'her move');
    if(!txt){el.style.display='none';return;}
    el.textContent=txt; el.style.display='block';
  }
  function poll(){
    fetch('/thinking',{cache:'no-store'}).then(function(r){return r.json();})
      .then(function(j){j.at=Date.now();s=j;paint();}).catch(function(){});
  }
  setInterval(poll,2000); setInterval(paint,1000); poll();
})();
</script>
""" % {"name": ASSISTANT_NAME}).encode()


def log(msg):
    print(f"chessweb: {msg}", flush=True)


# ------------------------------------------------------------- protobuf-lite
# The six non-empty messages use only varint and length-delimited fields, so a
# generic coder is smaller and less wrong than a generated one.

def uvarint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_uvarint(buf, i):
    shift = val = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def parse_fields(payload):
    """{field number: last value} — int for varint, bytes for length-delimited."""
    fields, i = {}, 0
    while i < len(payload):
        tag, i = read_uvarint(payload, i)
        num, wt = tag >> 3, tag & 7
        if wt == 0:
            fields[num], i = read_uvarint(payload, i)
        elif wt == 2:
            size, i = read_uvarint(payload, i)
            fields[num] = bytes(payload[i:i + size])
            i += size
        else:
            raise ValueError(f"wire type {wt} unexpected here")
    return fields


def emit_fields(pairs):
    """pairs of (field number, int | bytes); zero ints are omitted (proto3)."""
    out = bytearray()
    for num, val in pairs:
        if isinstance(val, int):
            if val:
                out += uvarint(num << 3) + uvarint(val)
        else:
            out += uvarint(num << 3 | 2) + uvarint(len(val)) + val
    return bytes(out)


def server_msg(mtype, payload=b""):
    """One server→client protocol message. A Ping is its type byte alone —
    the stock reader consumes no length for Ping."""
    if mtype == PING:
        return bytes([PING])
    return bytes([mtype]) + uvarint(len(payload)) + payload


def msg_error(text):
    return server_msg(ERROR, emit_fields([(1, text.encode())]))


def msg_move(fx, fy, tx, ty, mtype):
    return server_msg(MOVE, emit_fields(
        [(1, fx), (2, fy), (3, tx), (4, ty), (5, mtype)]))


def msg_promote(x, y, rune):
    return server_msg(PROMOTE, emit_fields([(1, x), (2, y), (3, rune)]))


class MsgStream:
    """Client→server bytes to (type, payload) messages. The stream crosses
    WebSocket message boundaries; lengths are one byte (the stock server's
    reading side), and a client Ping is a bare type byte."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        msgs = []
        while self.buf:
            if self.buf[0] == PING:
                del self.buf[:1]
                msgs.append((PING, b""))
                continue
            if len(self.buf) < 2:
                break
            size = self.buf[1]
            if len(self.buf) < 2 + size:
                break
            msgs.append((self.buf[0], bytes(self.buf[2:2 + size])))
            del self.buf[:2 + size]
        return msgs


# ------------------------------------------------------------- coordinates
# SpeedyChess boards are [y][x], y 0 at black's back rank: file = x, rank = 8-y.

def sq_to_xy(square):
    return chess.square_file(square), 7 - chess.square_rank(square)


def xy_to_sq(x, y):
    if not (0 <= x <= 7 and 0 <= y <= 7):
        raise ValueError("off the board")
    return chess.square(x, 7 - y)


def wire_msgs_for_move(board, move):
    """The broadcasts that carry `move` (legal on `board`) to stock clients:
    one Move, plus a Promote for a promotion."""
    fx, fy = sq_to_xy(move.from_square)
    if board.is_castling(move):
        mtype = CASTLE_LEFT if chess.square_file(move.to_square) < 4 \
            else CASTLE_RIGHT
        tx, ty = sq_to_xy(move.to_square)
        return [msg_move(fx, fy, tx, ty, mtype)]
    if board.is_en_passant(move):
        # The wire's "to" is the captured pawn's square: the destination file,
        # the mover's own starting rank.
        tx = chess.square_file(move.to_square)
        ty = 7 - chess.square_rank(move.from_square)
        return [msg_move(fx, fy, tx, ty, EN_PASSANT)]
    tx, ty = sq_to_xy(move.to_square)
    out = [msg_move(fx, fy, tx, ty, REGULAR)]
    if move.promotion:
        rune = (WHITE_PROMO_RUNE if board.turn == chess.WHITE
                else BLACK_PROMO_RUNE)[move.promotion]
        out.append(msg_promote(tx, ty, rune))
    return out


def move_from_wire(board, f):
    """A wire Move (parsed fields) to a python-chess Move on `board`, or
    ("promote", base) when a legal pawn push needs its Promote answer first.
    Raises ValueError with a client-worthy message when it cannot be one."""
    fx, fy = f.get(1, 0), f.get(2, 0)
    mtype = f.get(5, 0)
    from_sq = xy_to_sq(fx, fy)
    piece = board.piece_at(from_sq)
    if piece is None:
        raise ValueError("There's no piece there.")
    if piece.color != board.turn:
        raise ValueError("That's not your piece.")

    if mtype in (CASTLE_LEFT, CASTLE_RIGHT):
        # Only the from-square is trustworthy: the stock AI sends castles with
        # no destination at all. King to the c- or g-file on its own rank.
        to_sq = chess.square(2 if mtype == CASTLE_LEFT else 6,
                             chess.square_rank(from_sq))
        move = chess.Move(from_sq, to_sq)
    elif mtype == EN_PASSANT:
        # The wire's to-square is the captured pawn; the destination is that
        # file, one rank past the mover.
        step = -1 if piece.color == chess.BLACK else 1
        to_sq = chess.square(f.get(3, 0),
                             chess.square_rank(from_sq) + step)
        move = chess.Move(from_sq, to_sq)
    else:
        to_sq = xy_to_sq(f.get(3, 0), f.get(4, 0))
        move = chess.Move(from_sq, to_sq)
        if (piece.piece_type == chess.PAWN
                and chess.square_rank(to_sq) in (0, 7)):
            probe = chess.Move(from_sq, to_sq, promotion=chess.QUEEN)
            if probe not in board.legal_moves:
                raise ValueError("That's not legal.")
            return "promote", move
    if move not in board.legal_moves:
        raise ValueError("That's not legal.")
    return "move", move


# ------------------------------------------------------------- websocket
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WSConn:
    """One accepted WebSocket, after the handshake. Reads yield the binary
    payloads; writes are one unmasked binary frame per protocol message."""

    def __init__(self, sock):
        self.sock = sock
        self.wlock = threading.Lock()
        self.dead = False

    def _read_exact(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("peer closed")
            data += chunk
        return bytes(data)

    def recv_messages(self):
        fragments = bytearray()
        while True:
            h0, h1 = self._read_exact(2)
            fin, opcode = h0 & 0x80, h0 & 0x0F
            masked, length = h1 & 0x80, h1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else b"\x00" * 4
            payload = bytearray(self._read_exact(length))
            for i in range(length):
                payload[i] ^= mask[i & 3]
            if opcode == 8:
                self.send_frame(8, bytes(payload[:2]))
                return
            if opcode == 9:
                self.send_frame(10, bytes(payload))
                continue
            if opcode == 10:
                continue
            fragments += payload
            if fin:
                out, fragments = bytes(fragments), bytearray()
                if opcode in (0, 2):
                    yield out
                # text frames carry nothing in this protocol; dropped

    def send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(n)
        elif n < 1 << 16:
            header.append(126)
            header += struct.pack(">H", n)
        else:
            header.append(127)
            header += struct.pack(">Q", n)
        with self.wlock:
            self.sock.sendall(bytes(header) + payload)

    def send(self, data):
        """Binary app data. Marks the connection dead on any failure."""
        try:
            self.send_frame(2, data)
            return True
        except OSError:
            self.dead = True
            return False


# ------------------------------------------------------------- the store

class Store:
    """The bridge's one view of the betty-chess game files. Every read is from
    disk; every write goes through chess_cli.save_game. No cached truth."""

    def __init__(self, opponent, her_side, game_id=None):
        self.opponent = opponent
        self.her_side = her_side  # "white" or "black"
        self.game_id = game_id

    def load(self):
        # Newest first, and the choice is pinned: the poll must keep watching
        # the same game the browser was shown, not whichever matches next.
        for g in reversed(chess_cli.load_all()):
            if self.game_id:
                if g["id"] == self.game_id:
                    self.her_side = g["my_side"]
                    return g
                continue
            if (chess_cli.slugify(g["opponent"])
                    == chess_cli.slugify(self.opponent)
                    and chess_cli.compute_state(
                        g, chess_cli.build_board(g))[0] == "active"):
                # The stored game's sides are the truth; --human-side only
                # shapes a game that does not exist yet.
                self.game_id = g["id"]
                self.her_side = g["my_side"]
                return g
        return None

    def create(self):
        slug = chess_cli.slugify(self.opponent)
        taken = {g["id"] for g in chess_cli.load_all()}
        n = 1
        while f"{slug}-{n:03d}" in taken:
            n += 1
        g = {"id": f"{slug}-{n:03d}", "opponent": self.opponent,
             "my_side": self.her_side, "moves": [], "resigned_by": None,
             "draw_agreed": False, "engine_level": None,
             "created": chess_cli.now()}
        chess_cli.save_game(g)
        self.game_id = g["id"]
        log(f"created {g['id']}: the user is "
            f"{'black' if self.her_side == 'white' else 'white'}")
        return g


# ------------------------------------------------------------- the hub

class Hub:
    def __init__(self, store, wake_cmd, poll_interval=1.0):
        self.store = store
        self.wake_cmd = wake_cmd
        self.poll_interval = poll_interval
        self.lock = threading.RLock()
        self.conns = {}          # WSConn -> "seat" | "observer" | "none"
        self.seat = None
        self.synced = None       # move list each connection has been shown
        self.over_announced = False
        self.pending_promo = None  # chess.Move awaiting its Promote answer
        # What the browser is told about her side of the clock. Without it a
        # think and a bridge that never woke her look identical from the phone.
        self.activity = {"poked_at": None, "started_at": None,
                         "played_at": None, "san": None}
        self.port = None

    # -- helpers -----------------------------------------------------------
    def human_side(self):
        return chess.BLACK if self.store.her_side == "white" else chess.WHITE

    def joined(self):
        return [c for c, role in list(self.conns.items())
                if role in ("seat", "observer")]

    def broadcast(self, data):
        for conn in self.joined():
            conn.send(data)

    def result_msg(self, key, result):
        code = {"1-0": RESULT_WHITE_WIN, "0-1": RESULT_BLACK_WIN}.get(
            result, RESULT_STALEMATE)
        return server_msg(GAME_COMPLETE, emit_fields([(1, code)]))

    def sync_conn(self, conn, g):
        """Team + full replay: the stock client rebuilds board and turn from
        exactly this sequence."""
        black = self.human_side() == chess.BLACK
        if self.conns.get(conn) == "observer":
            black = False  # observers watch from white's side, as stock does
        conn.send(server_msg(TEAM, emit_fields([(1, int(black))])))
        board = chess.Board()
        for uci in g["moves"]:
            move = chess.Move.from_uci(uci)
            for m in wire_msgs_for_move(board, move):
                conn.send(m)
            board.push(move)
        key, _desc, result = chess_cli.compute_state(g, board)
        if key != "active":
            conn.send(self.result_msg(key, result))

    def record_move(self, g, board, move):
        """Append a validated move, broadcast it, close the game if it ended,
        wake her if it is now her turn. The one write path for user moves."""
        msgs = wire_msgs_for_move(board, move)
        san = board.san(move)
        board.push(move)
        g["moves"].append(move.uci())
        chess_cli.save_game(g)
        self.synced = list(g["moves"])
        for m in msgs:
            self.broadcast(m)
        key, desc, result = chess_cli.compute_state(g, board)
        log(f"{g['id']}: the user played {san} ({desc})")
        if key != "active":
            self.over_announced = True
            self.broadcast(self.result_msg(key, result))
            self.dispatch_wake(g, board, san, over=f"{desc} [{result}]")
        else:
            self.dispatch_wake(g, board, san)

    def notify_phone(self):
        # The board banner is only useful to someone looking at the board; a
        # push says "she has started" wherever the user happens to be.
        try:
            subprocess.run(["crab", "notify", f"{ASSISTANT_NAME} is thinking about her "
                            f"chess move"], capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"notify failed: {e}")

    def try_reflex(self, g, board):
        """Her move from memory instead of from a wake, when the position is
        known well enough (specs/chess-reflex.md rules 7 and 8). True means
        the move is played, saved, and broadcast — book no wake. Any failure
        here is a fall-through to thinking, never a lost turn."""
        if os.environ.get("DESKCRAB_CHESS_REFLEX", "1") == "0":
            return False
        try:
            best = chess_reflex.best_move(board.fen(), board)
        except Exception as e:
            log(f"reflex lookup failed, thinking instead: {e}")
            return False
        if best is None:
            return False
        move = chess.Move.from_uci(best["move"])
        msgs = wire_msgs_for_move(board, move)
        san = board.san(move)
        board.push(move)
        g["moves"].append(move.uci())
        chess_cli.save_game(g)
        self.synced = list(g["moves"])
        for m in msgs:
            self.broadcast(m)
        self.activity.update(poked_at=None, started_at=None,
                             played_at=time.time(), san=san)
        key, desc, result = chess_cli.compute_state(g, board)
        log(f"{g['id']}: reflex played {san} from memory "
            f"({best['n']} game(s), score {best['score']:.2f}) — no wake")
        if key != "active":
            self.over_announced = True
            self.broadcast(self.result_msg(key, result))
            # She still hears how her game ended, even when memory ended it.
            self.dispatch_wake(g, board, san, over=f"{desc} [{result}]")
        return True

    def dispatch_wake(self, g, board, san=None, over=None):
        if over is None and self.try_reflex(g, board):
            return
        gid = g["id"]
        history = chess_cli.history(g["moves"])
        if over:
            reason = (f"chessweb: the game against {g['opponent']} ({gid}) "
                      f"just ended — {over}, after {san}. "
                      f"History: {history}. Board: betty-chess show {gid}")
        else:
            played = f"they played {san}. " if san else ""
            # Off the board, not the dict: the ply must name the very position
            # this reason quotes, whatever the store has done since.
            ply = len(board.move_stack)
            reason = (f"chessweb: your move as {self.store.her_side} against "
                      f"{g['opponent']} in game {gid} — {played}"
                      f"FEN: {board.fen()}. History: {history}. This is the "
                      f"board at ply {ply}, photographed when the wake was "
                      f"booked. Choose your reply and play it with: "
                      f"betty-chess move {gid} <move> --expect-ply {ply} — the "
                      f"guard refuses it if the game moved on while you "
                      f"thought, and it reaches their browser within seconds. "
                      f"See the board as it stands: betty-chess show {gid}")
        if self.port:
            reason += (f". Before you think, say so: curl -sf -X POST "
                       f"http://127.0.0.1:{self.port}/thinking -o /dev/null "
                       f"— it lights the thinking line on the user's board")
        cmd = self.wake_cmd + [reason]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=30)
            if r.returncode != 0:
                log(f"wake failed ({r.returncode}): "
                    f"{(r.stderr or r.stdout).strip()}")
            else:
                log(f"wake booked: her move in {gid}")
                self.activity.update(poked_at=time.time(), started_at=None,
                                     played_at=None, san=None)
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"wake failed: {e}")

    # -- protocol ----------------------------------------------------------
    def on_join(self, conn, player):
        if not player:
            self.conns[conn] = "observer"
            g = self.store.load()
            if g:
                self.sync_conn(conn, g)
            return
        if self.conns.get(conn) == "seat":
            conn.send(msg_error("You're already a player."))
            return
        if self.seat is not None and self.seat is not conn:
            # A dead seat is freed by the probe; a live one keeps its chair.
            if self.seat.send(server_msg(PING)) and not self.seat.dead:
                conn.send(msg_error("All player slots filled."))
                return
            self.conns.pop(self.seat, None)
            self.seat = None
        self.seat = conn
        self.conns[conn] = "seat"
        conn.send(server_msg(PLAYER, emit_fields([(1, 1)])))
        conn.send(server_msg(OPPONENT_JOINED))  # she is always present
        # A rejoin lands on the live game (rule 3): load, never create, and
        # replay the position at once — the seat must not need a NewGame
        # click, which on a finished game would start a fresh one.
        g = self.store.load()
        if g and chess_cli.compute_state(
                g, chess_cli.build_board(g))[0] == "active":
            # If the poll still owes other connections a delta, a resync of
            # everyone keeps `synced` truthful for all of them.
            stale = self.synced is not None and self.synced != g["moves"]
            self.synced = list(g["moves"])
            for c in (self.joined() if stale else [conn]):
                self.sync_conn(c, g)

    def on_newgame(self, conn):
        if conn is not self.seat:
            conn.send(msg_error("Only player 1 can start a game."))
            return
        self.pending_promo = None
        g = self.store.load()
        if g is None or chess_cli.compute_state(
                g, chess_cli.build_board(g))[0] != "active":
            g = self.store.create()
        self.synced = list(g["moves"])
        self.over_announced = False
        for c in self.joined():
            self.sync_conn(c, g)
        board = chess_cli.build_board(g)
        turn = "white" if board.turn == chess.WHITE else "black"
        log(f"{g['id']} synced to {len(self.conns)} connection(s), "
            f"{turn} to move")
        if board.turn != self.human_side():
            self.dispatch_wake(g, board)

    def on_move(self, conn, fields):
        if conn is not self.seat:
            conn.send(msg_error("It's not your turn."))
            return
        if self.pending_promo is not None:
            conn.send(msg_error("Waiting on your promotion pick."))
            return
        g = self.store.load()
        if g is None:
            conn.send(msg_error("Game has not started."))
            return
        board = chess_cli.build_board(g)
        if chess_cli.compute_state(g, board)[0] != "active":
            conn.send(msg_error("Game has not started."))
            return
        if board.turn != self.human_side():
            conn.send(msg_error("It's not your turn."))
            return
        try:
            kind, move = move_from_wire(board, fields)
        except ValueError as e:
            conn.send(msg_error(str(e)))
            return
        if kind == "promote":
            # Stock behaviour: the pawn's Move is broadcast at once, the mover
            # is prompted, and nothing is recorded until the answer.
            self.pending_promo = move
            fx, fy = sq_to_xy(move.from_square)
            tx, ty = sq_to_xy(move.to_square)
            self.broadcast(msg_move(fx, fy, tx, ty, REGULAR))
            conn.send(server_msg(PROMOTE, emit_fields([(1, tx), (2, ty)])))
            return
        self.record_move(g, board, move)

    def on_promote(self, conn, fields):
        if conn is not self.seat or self.pending_promo is None:
            conn.send(msg_error("You're not ready for a promotion yet."))
            return
        rune = fields.get(3, 0)
        promo = RUNE_TO_PROMO.get(rune)
        white_mover = self.human_side() == chess.WHITE
        if promo is None or RUNE_IS_WHITE.get(rune) != white_mover:
            conn.send(msg_error("Invalid selection."))
            return
        base = self.pending_promo
        move = chess.Move(base.from_square, base.to_square, promotion=promo)
        g = self.store.load()
        board = chess_cli.build_board(g) if g else None
        if g is None or move not in board.legal_moves:
            # The store moved under the pending pick; resync rather than guess.
            self.pending_promo = None
            if g:
                for c in self.joined():
                    self.sync_conn(c, g)
            return
        self.pending_promo = None
        tx, ty = sq_to_xy(move.to_square)
        # record_move would re-send the Move half; the promotion's Move is
        # already on every board, so record by hand and broadcast the Promote.
        san = board.san(move)
        board.push(move)
        g["moves"].append(move.uci())
        chess_cli.save_game(g)
        self.synced = list(g["moves"])
        self.broadcast(msg_promote(tx, ty, rune))
        key, desc, result = chess_cli.compute_state(g, board)
        log(f"{g['id']}: the user played {san} ({desc})")
        if key != "active":
            self.over_announced = True
            self.broadcast(self.result_msg(key, result))
            self.dispatch_wake(g, board, san, over=f"{desc} [{result}]")
        else:
            self.dispatch_wake(g, board, san)

    def on_message(self, conn, mtype, payload):
        with self.lock:
            if mtype == PING:
                return
            fields = parse_fields(payload) if payload else {}
            if mtype == JOIN:
                self.on_join(conn, bool(fields.get(1, 0)))
            elif mtype == NEWGAME:
                self.on_newgame(conn)
            elif mtype == MOVE:
                self.on_move(conn, fields)
            elif mtype == PROMOTE:
                self.on_promote(conn, fields)

    def run_conn(self, conn):
        with self.lock:
            self.conns[conn] = "none"
        stream = MsgStream()
        try:
            for data in conn.recv_messages():
                for mtype, payload in stream.feed(data):
                    self.on_message(conn, mtype, payload)
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            with self.lock:
                role = self.conns.pop(conn, None)
                if conn is self.seat:
                    self.seat = None
                    self.pending_promo = None
                if role == "seat":
                    log("the user's seat disconnected")

    def keepalive(self):
        # The stock clients hang up after 120 idle seconds; the stock server
        # pings every 25. A chess game is mostly idle, so without this every
        # browser drops two minutes into her think.
        while True:
            time.sleep(25)
            with self.lock:
                self.broadcast(server_msg(PING))

    # -- the store watch ---------------------------------------------------
    def poll_store(self):
        while True:
            time.sleep(self.poll_interval)
            with self.lock:
                try:
                    self.poll_once()
                except Exception as e:  # a poll must never kill the serve
                    log(f"store poll: {e}")

    def poll_once(self):
        if self.synced is None:
            return  # nothing shown to anyone yet; NewGame does the first sync
        g = self.store.load() if self.store.game_id else None
        if g is None:
            return
        moves = g["moves"]
        if moves == self.synced:
            pass
        elif (len(moves) > len(self.synced)
                and moves[:len(self.synced)] == self.synced):
            board = chess.Board()
            for uci in self.synced:
                board.push(chess.Move.from_uci(uci))
            for uci in moves[len(self.synced):]:
                move = chess.Move.from_uci(uci)
                san = board.san(move)
                for m in wire_msgs_for_move(board, move):
                    self.broadcast(m)
                board.push(move)
                log(f"{g['id']}: mirrored {san} to the browser")
                self.activity.update(poked_at=None, started_at=None,
                                     played_at=time.time(), san=san)
            self.synced = list(moves)
            self.pending_promo = None
        else:
            # Undo or rewrite: no delta is trustworthy, so replay everything.
            log(f"{g['id']}: history changed on disk — full resync")
            self.synced = list(moves)
            self.pending_promo = None
            self.over_announced = False
            for c in self.joined():
                self.sync_conn(c, g)
        key, _desc, result = chess_cli.compute_state(
            g, chess_cli.build_board(g))
        if key != "active" and not self.over_announced:
            self.over_announced = True
            self.broadcast(self.result_msg(key, result))
        elif key == "active":
            self.over_announced = False


# ------------------------------------------------------------- HTTP + serve

class Server(ThreadingHTTPServer):
    # A phone roaming between networks resets sockets all night, and every
    # reset used to print a full handler-thread traceback (rule 14). One line
    # for the connection family; a stack trace in this log means a bug.
    def handle_error(self, request, client_address):
        exc = sys.exception()
        if isinstance(exc, (ConnectionError, TimeoutError)):
            log(f"client {client_address[0]} dropped: {exc!r}")
            return
        super().handle_error(request, client_address)


def make_handler(hub, client_dir):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        # Unbuffered reads: a buffered rfile can swallow WebSocket frames that
        # arrive on the heels of the handshake, and WSConn reads the raw
        # socket.
        rbufsize = 0

        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.headers.get("Upgrade", "").lower() == "websocket":
                self.upgrade()
                return
            if self.path.split("?", 1)[0] == "/thinking":
                self.thinking_state()
                return
            self.static()

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/thinking":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            with hub.lock:
                first = hub.activity["started_at"] is None
                if first:
                    hub.activity["started_at"] = time.time()
            if first:
                hub.notify_phone()
            self.json_body({"ok": True})

        def thinking_state(self):
            with hub.lock:
                state = dict(hub.activity)
            state["now"] = time.time()
            self.json_body(state)

        def json_body(self, obj):
            body = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def upgrade(self):
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1(
                (key + WS_GUID).encode()).digest()).decode()
            self.wfile.write(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n\r\n")
            self.close_connection = True
            hub.run_conn(WSConn(self.connection))

        def static(self):
            name = self.path.split("?", 1)[0].lstrip("/") or "index.html"
            target = (client_dir / name).resolve()
            if not (str(target).startswith(str(client_dir.resolve()) + os.sep)
                    or target == client_dir.resolve()) or not target.is_file():
                self.send_error(404)
                return
            body = target.read_bytes()
            if target.name == "index.html":
                host = self.headers.get("Host", "127.0.0.1")
                body = re.sub(
                    rb'(id="serveraddr"\s+value=")[^"]*(")',
                    lambda m: m.group(1) + host.encode() + m.group(2), body)
                body = body.replace(b"</body>", THINKING_WIDGET + b"</body>",
                                    1)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPES.get(
                target.suffix, "application/octet-stream"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def find_client_dir(arg):
    candidates = [arg, os.environ.get("DESKCRAB_CHESSWEB_CLIENT"),
                  Path.home() / ".local/share/deskcrab/chessweb/client"]
    for c in candidates:
        if c and (Path(c) / "index.html").is_file():
            return Path(c)
    sys.exit("chessweb: no SpeedyChess client directory. Build the client "
             "(make config && make in its checkout), then point --client or "
             "$DESKCRAB_CHESSWEB_CLIENT at it, or symlink it to "
             "~/.local/share/deskcrab/chessweb/client")


def default_wake_cmd():
    override = os.environ.get("DESKCRAB_CHESSWEB_WAKE_CMD")
    if override:
        return shlex.split(override)
    crab = Path(__file__).resolve().parent.parent / "crab"
    return [str(crab) if crab.is_file() else "crab",
            "wake-at", "--by", "chessweb", "1s", "event"]


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="betty-chessweb",
        description="Serve a browser board onto a betty-chess game.")
    sub = p.add_subparsers(dest="command", required=True)
    sp = sub.add_parser("serve", help="host the board and the game protocol")
    sp.add_argument("--port", type=int,
                    default=int(os.environ.get("DESKCRAB_CHESSWEB_PORT",
                                               "8181")))
    sp.add_argument("--opponent", default="browser",
                    help="who the user is in the betty-chess store")
    sp.add_argument("--human-side", choices=["white", "black"],
                    default="white", help="the user's colour in a NEW game")
    sp.add_argument("--game", default=None,
                    help="pin a betty-chess game id instead of newest-active")
    sp.add_argument("--client", default=None,
                    help="the SpeedyChess client directory")
    sp.add_argument("--poll", type=float, default=1.0,
                    help=argparse.SUPPRESS)  # tests tighten it
    args = p.parse_args(argv)

    client_dir = find_client_dir(args.client)
    her_side = "black" if args.human_side == "white" else "white"
    store = Store(args.opponent, her_side, args.game)
    hub = Hub(store, default_wake_cmd(), args.poll)

    httpd = Server(("", args.port), make_handler(hub, client_dir))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    hub.port = port
    log(f"serving {client_dir} and the game protocol on port {port}")
    log(f"open http://<this host>:{port}/ then Connect, Join, New Game")

    g = store.load()
    if g:
        board = chess_cli.build_board(g)
        key, desc, _r = chess_cli.compute_state(g, board)
        log(f"resuming {g['id']}: {desc}")
        if key == "active" and board.turn != hub.human_side():
            hub.dispatch_wake(g, board)  # the bridge died before booking
    else:
        log(f"no active game against {args.opponent} yet — "
            "one is created when the user clicks New Game")

    threading.Thread(target=hub.poll_store, daemon=True).start()
    threading.Thread(target=hub.keepalive, daemon=True).start()
    while True:
        try:
            httpd.serve_forever()
            return 0
        except KeyboardInterrupt:
            return 0
        except Exception as e:
            # Rule 14: nothing that escapes a connection may take the
            # listener down. The socket is still bound; keep accepting.
            log(f"serve loop survived: {e!r}")


if __name__ == "__main__":
    sys.exit(main())
