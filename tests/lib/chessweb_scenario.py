#!/usr/bin/env python3
"""Test-side SpeedyChess client for tests/test_chessweb.sh.

Speaks the wire exactly as the stock WASM client does — masked WebSocket
frames, client framing out (one-byte lengths, bare Ping), server framing in
(uvarint lengths, bare Ping) — so a bridge that satisfies this file speaks to
the real page. Each subcommand is one scenario against a bridge the shell has
already started; assertions print "  ok: ..." and any failure raises."""

import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

PING, JOIN, NEWGAME, MOVE, ERROR, TEAM, PLAYER, \
    OPPONENT_LEFT, OPPONENT_JOINED, PROMOTE, GAME_COMPLETE = range(11)
NAMES = ["Ping", "Join", "NewGame", "Move", "Error", "Team", "Player",
         "OpponentLeft", "OpponentJoined", "Promote", "GameComplete"]

REPO = Path(__file__).resolve().parent.parent.parent
VENV_PY = sys.executable


def ok(msg):
    print(f"  ok: {msg}")


def uvarint_read(recv_byte):
    shift = val = 0
    while True:
        b = recv_byte()
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val
        shift += 7


def fields(payload):
    out, i = {}, 0
    while i < len(payload):
        tag = payload[i]
        i += 1
        num, wt = tag >> 3, tag & 7
        if wt == 0:
            val = shift = 0
            while True:
                b = payload[i]
                i += 1
                val |= (b & 0x7F) << shift
                if not b & 0x80:
                    break
                shift += 7
            out[num] = val
        else:
            size = payload[i]
            i += 1
            out[num] = payload[i:i + size]
            i += size
    return out


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.sock.sendall(
            b"GET / HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\n"
            b"Connection: Upgrade\r\nSec-WebSocket-Key: dGVzdHRlc3R0ZXN0dGU=\r\n"
            b"Sec-WebSocket-Version: 13\r\n\r\n")
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        assert b"101" in head.split(b"\r\n")[0], head
        self.rbuf = bytearray()

    # -- websocket ---------------------------------------------------------
    def _raw(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return bytes(data)

    def send_ws(self, payload):
        mask = b"\x11\x22\x33\x44"
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        n = len(payload)
        if n < 126:
            header = struct.pack(">BB", 0x82, 0x80 | n)
        else:
            header = struct.pack(">BBH", 0x82, 0x80 | 126, n)
        self.sock.sendall(header + mask + masked)

    def _ws_payload(self):
        while True:
            h0, h1 = self._raw(2)
            n = h1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._raw(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._raw(8))[0]
            data = self._raw(n)
            op = h0 & 0x0F
            if op in (0, 2):
                return data
            if op == 8:
                raise ConnectionError("server closed")
            # ws ping/pong/text: not part of this protocol, skip

    # -- protocol ----------------------------------------------------------
    def send(self, mtype, payload=b""):
        if mtype == PING:
            self.send_ws(bytes([PING]))
            return
        assert len(payload) < 256
        self.send_ws(bytes([mtype, len(payload)]) + payload)

    def recv(self, timeout=5.0):
        """Next protocol message, Pings skipped."""
        deadline = time.time() + timeout
        while True:
            if self.rbuf:
                t = self.rbuf[0]
                if t == PING:
                    del self.rbuf[:1]
                    continue
                # uvarint length
                i, shift, size = 1, 0, 0
                ok_len = False
                while i < len(self.rbuf):
                    b = self.rbuf[i]
                    size |= (b & 0x7F) << shift
                    i += 1
                    if not b & 0x80:
                        ok_len = True
                        break
                    shift += 7
                if ok_len and len(self.rbuf) >= i + size:
                    payload = bytes(self.rbuf[i:i + size])
                    del self.rbuf[:i + size]
                    return t, payload
            self.sock.settimeout(max(0.05, deadline - time.time()))
            try:
                self.rbuf += self._ws_payload()
            except socket.timeout:
                raise AssertionError(f"timed out waiting; buffer={bytes(self.rbuf)!r}")

    def expect(self, mtype, timeout=5.0):
        t, payload = self.recv(timeout)
        assert t == mtype, f"wanted {NAMES[mtype]}, got {NAMES[t]} " \
                           f"fields={fields(payload)}"
        return fields(payload)

    # -- moves in wire coordinates ----------------------------------------
    @staticmethod
    def enc(pairs):
        out = bytearray()
        for num, val in pairs:
            if isinstance(val, int):
                if val:
                    out += bytes([num << 3])
                    v = val
                    while True:
                        b = v & 0x7F
                        v >>= 7
                        out.append(b | 0x80 if v else b)
                        if not v:
                            break
            else:
                out += bytes([num << 3 | 2, len(val)]) + val
        return bytes(out)

    @staticmethod
    def xy(sq):  # "e2" -> wire x, y
        return ord(sq[0]) - 97, 8 - int(sq[1])

    def move(self, frm, to, mtype=0):
        fx, fy = self.xy(frm)
        tx, ty = self.xy(to)
        self.send(MOVE, self.enc([(1, fx), (2, fy), (3, tx), (4, ty),
                                  (5, mtype)]))

    def join(self, player=True):
        self.send(JOIN, self.enc([(1, int(player))]))

    def expect_move(self, frm, to, mtype=0):
        f = self.expect(MOVE)
        fx, fy = self.xy(frm)
        tx, ty = self.xy(to)
        got = (f.get(1, 0), f.get(2, 0), f.get(3, 0), f.get(4, 0),
               f.get(5, 0))
        assert got == (fx, fy, tx, ty, mtype), \
            f"move {frm}->{to} type {mtype}: wire said {got}"


def hard_reset(sock):
    """Close with SO_LINGER 0: the peer sees RST, not FIN — the abrupt death
    a phone roaming off the network hands the bridge all night."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                    struct.pack("ii", 1, 0))
    sock.close()


def her_move(chess_dir, gid, move):
    """Her reply path: the real betty-chess CLI against the same store."""
    env = dict(os.environ, DESKCRAB_CHESS_DIR=chess_dir,
               PYTHONDONTWRITEBYTECODE="1")
    r = subprocess.run([VENV_PY, str(REPO / "lib/chess_cli.py"),
                        "move", gid, move],
                       capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, f"betty-chess move {move}: {r.stderr}"


def game_moves(chess_dir, gid):
    with open(Path(chess_dir) / "games" / f"{gid}.json") as f:
        return json.load(f)["moves"]


def seed(chess_dir, gid, opponent, my_side, moves):
    games = Path(chess_dir) / "games"
    games.mkdir(parents=True, exist_ok=True)
    with open(games / f"{gid}.json", "w") as f:
        json.dump({"id": gid, "opponent": opponent, "my_side": my_side,
                   "moves": moves, "resigned_by": None, "draw_agreed": False,
                   "engine_level": None, "created": "2026-01-01T00:00:00+00:00",
                   "updated": "2026-01-01T00:00:00+00:00"}, f)


# ---------------------------------------------------------------- scenarios

def s_http(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=10) as r:
        page = r.read().decode()
    assert f'value="127.0.0.1:{port}"' in page, "serveraddr not rewritten"
    ok("index.html server box rewritten to the request host")
    req = urllib.request.Request(f"http://127.0.0.1:{port}/chess.wasm")
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.headers["Content-Type"] == "application/wasm"
    ok("chess.wasm served as application/wasm")
    try:
        urllib.request.urlopen(
            f"http://127.0.0.1:{port}/%2e%2e/secret", timeout=10)
        raise AssertionError("traversal fetched a file")
    except urllib.error.HTTPError as e:
        assert e.code == 404
    ok("path traversal refused")


def s_fresh(port, chess_dir, wake_log):
    c = Client(port)
    c.join()
    f = c.expect(PLAYER)
    assert f.get(1, 0) == 1
    c.expect(OPPONENT_JOINED)
    ok("seated: Player{one} then OpponentJoined")

    c2 = Client(port)
    c2.join()
    f = c2.expect(ERROR)
    assert b"slots filled" in f[1]
    ok("second player join refused while the seat is live")

    c.send(NEWGAME)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 0, "the user should be white"
    ok("NewGame created a game and dealt the user white")

    c.move("e2", "e5")
    f = c.expect(ERROR)
    assert f[1] == b"That's not legal."
    assert game_moves(chess_dir, "guest-001") == []
    ok("illegal move refused, store untouched")

    c.move("e2", "e4")
    c.expect_move("e2", "e4")
    assert game_moves(chess_dir, "guest-001") == ["e2e4"]
    ok("e4 validated, recorded, echoed")

    c.move("d2", "d4")
    f = c.expect(ERROR)
    assert f[1] == b"It's not your turn."
    ok("moving on her turn refused")

    deadline = time.time() + 5
    wake = ""
    while time.time() < deadline and "guest-001" not in wake:
        wake = Path(wake_log).read_text() if Path(wake_log).exists() else ""
        time.sleep(0.1)
    assert "guest-001" in wake and "FEN:" in wake \
        and "betty-chess move guest-001" in wake and "e4" in wake, wake
    ok("wake booked with game id, SAN, FEN, and the reply instruction")

    # The photograph must say when it was taken: one ply played, so a reply
    # worked out from this text is only valid against ply 1.
    assert "--expect-ply 1" in wake, wake
    ok("and the ply it was booked at, as the guard on the reply")

    her_move(chess_dir, "guest-001", "e5")
    c.expect_move("e7", "e5")
    ok("her betty-chess reply mirrored to the browser")

    obs = Client(port)
    obs.join(player=False)
    obs.expect(TEAM)
    obs.expect_move("e2", "e4")
    obs.expect_move("e7", "e5")
    ok("an observer gets the replay at once")


def s_resume(port, chess_dir):
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 0
    c.expect_move("e2", "e4")
    c.expect_move("e7", "e5")
    ok("restarted bridge replayed the stored game on join alone")

    c.send(NEWGAME)  # rule 4 on an active game: resync, never a fresh start
    c.expect(TEAM)
    c.expect_move("e2", "e4")
    c.expect_move("e7", "e5")
    assert sorted(os.listdir(Path(chess_dir) / "games")) == ["guest-001.json"]
    assert game_moves(chess_dir, "guest-001") == ["e2e4", "e7e5"]
    ok("NewGame on the active game resynced it rather than starting fresh")

    env = dict(os.environ, DESKCRAB_CHESS_DIR=chess_dir,
               PYTHONDONTWRITEBYTECODE="1")
    r = subprocess.run([VENV_PY, str(REPO / "lib/chess_cli.py"),
                        "undo", "guest-001"],
                       capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, r.stderr
    c.expect(TEAM)
    c.expect_move("e2", "e4")
    ok("an undo on disk forced a full resync")


def s_special(port, chess_dir):
    # Seeded history: white castled kingside at ply 7, en passant at ply 9.
    # The seeded game is active, so the seat is synced on join (rule 3).
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 1, "the user should be black here"
    for frm, to in [("e2", "e4"), ("g7", "g6"), ("g1", "f3"), ("f8", "g7"),
                    ("f1", "e2"), ("g8", "f6")]:
        c.expect_move(frm, to)
    c.expect_move("e1", "g1", mtype=3)
    ok("kingside castle replayed as CastleRight from the king's square")
    c.expect_move("c7", "c5")
    c.expect_move("e4", "e5")
    c.expect_move("d7", "d5")
    c.expect_move("e5", "d5", mtype=1)
    ok("en passant replayed carrying the captured pawn's square")


def s_promote(port, chess_dir):
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    c.expect(TEAM)
    for _ in range(8):
        c.recv()  # the seeded replay; encodings proven in s_special

    c.move("b7", "a8")  # pawn takes the rook, promotion pending
    c.expect_move("b7", "a8")
    f = c.expect(PROMOTE)
    assert f.get(3, 0) == 0, "prompt must carry to=0"
    ok("promotion push broadcast, then the prompt")

    c.move("g1", "f3")
    f = c.expect(ERROR)
    assert b"promotion" in f[1]
    ok("other moves refused while the pick is pending")
    assert game_moves(chess_dir, "promo-001") == \
        ["b2b4", "a7a5", "b4a5", "b7b6", "a5b6", "c7c5", "b6b7", "c5c4"]
    ok("nothing recorded before the pick")

    c.send(PROMOTE, c.enc([(1, 0), (2, 0), (3, 0x265B)]))  # black queen
    f = c.expect(ERROR)
    assert f[1] == b"Invalid selection."
    ok("wrong-colour promotion rune refused")

    c.send(PROMOTE, c.enc([(1, 0), (2, 0), (3, 0x2655)]))  # white queen
    f = c.expect(PROMOTE)
    assert f.get(3, 0) == 0x2655
    assert game_moves(chess_dir, "promo-001")[-1] == "b7a8q"
    ok("promotion recorded as b7a8q and broadcast with the rune")


def s_mate(port, chess_dir, wake_log):
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    c.expect(TEAM)
    for _ in range(6):
        c.recv()
    c.move("h5", "f7")  # Qxf7#
    c.expect_move("h5", "f7")
    f = c.expect(GAME_COMPLETE)
    assert f.get(1, 0) == 2, f"wanted WhiteWin(2), got {f}"
    ok("checkmate by the user announced as WhiteWin")
    wake = Path(wake_log).read_text()
    assert "ended" in wake and "checkmate" in wake
    ok("the end-of-game wake tells her what happened")


def s_poller_end(port, chess_dir):
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    c.expect(TEAM)
    for _ in range(3):
        c.recv()
    her_move(chess_dir, "fools-001", "Qh4#")
    c.expect_move("d8", "h4")
    f = c.expect(GAME_COMPLETE)
    assert f.get(1, 0) == 1, f"wanted BlackWin(1), got {f}"
    ok("her mating move from the CLI ends the game as BlackWin")


def s_reflex(port, chess_dir, wake_log):
    # Two finished fool's mates were backfilled into reflex memory before the
    # bridge started. The user walks into the same trap: both of her replies
    # must come back from memory — instantly, with no thinking wake booked —
    # and the mate she remembers ends the game (specs/chess-reflex.md rule 8).
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    c.send(NEWGAME)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 0, "the user should be white"

    c.move("f2", "f3")
    c.expect_move("f2", "f3")
    c.expect_move("e7", "e5")
    ok("her reply to a remembered position arrived from reflex, no wake")

    c.move("g2", "g4")
    c.expect_move("g2", "g4")
    c.expect_move("d8", "h4")
    f = c.expect(GAME_COMPLETE)
    assert f.get(1, 0) == 1, f"wanted BlackWin(1), got {f}"
    ok("the remembered mate ended the game as BlackWin")

    assert game_moves(chess_dir, "guest-001") == \
        ["f2f3", "e7e5", "g2g4", "d8h4"]
    ok("reflex moves went through the store like any other move")

    deadline = time.time() + 5
    wake = ""
    while time.time() < deadline and "ended" not in wake:
        wake = Path(wake_log).read_text() if Path(wake_log).exists() else ""
        time.sleep(0.1)
    assert "your move" not in wake, f"a thinking wake was booked: {wake}"
    assert "ended" in wake and "checkmate" in wake, wake
    ok("no thinking wake was spent; the end-of-game wake still fired")

    import sqlite3
    n = sqlite3.connect(Path(chess_dir) / "reflex.db").execute(
        "SELECT COUNT(*) FROM games WHERE game_id = 'guest-001'"
    ).fetchone()[0]
    assert n == 1, "the game reflex just finished never entered the memory"
    ok("and the game reflex finished was itself ingested at game end")


def s_reset(port, chess_dir):
    # A peer reset at every point the night of 2026-08-09 hit: mid-request,
    # mid-upgrade, and under the poll thread's broadcast. Survival is the
    # shell's assertion (the pid); this scenario proves play continues.
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(b"GET / HT")
    hard_reset(s)
    ok("reset mid-request sent")

    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(b"GET / HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\n"
              b"Connection: Upgrade\r\n"
              b"Sec-WebSocket-Key: dGVzdHRlc3R0ZXN0dGU=\r\n"
              b"Sec-WebSocket-Version: 13\r\n\r\n")
    hard_reset(s)
    ok("reset mid-upgrade sent")
    time.sleep(0.3)

    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    c.send(NEWGAME)
    c.expect(TEAM)
    c.move("e2", "e4")
    c.expect_move("e2", "e4")
    obs = Client(port)
    obs.join(player=False)
    obs.expect(TEAM)
    obs.expect_move("e2", "e4")
    hard_reset(obs.sock)  # the poll's next broadcast lands on a corpse
    her_move(chess_dir, "guest-001", "e5")
    c.expect_move("e7", "e5")
    ok("broadcast into a reset observer; the live seat still got the move")

    c.move("g1", "f3")
    c.expect_move("g1", "f3")
    hard_reset(c.sock)    # now the seat itself dies under a broadcast
    her_move(chess_dir, "guest-001", "Nc6")
    time.sleep(0.5)

    c2 = Client(port)
    c2.join()
    c2.expect(PLAYER)
    c2.expect(OPPONENT_JOINED)
    f = c2.expect(TEAM)
    assert f.get(1, 0) == 0
    for frm, to in [("e2", "e4"), ("e7", "e5"), ("g1", "f3"), ("b8", "c6")]:
        c2.expect_move(frm, to)
    ok("after every reset the bridge still serves, seats, and replays")


def s_rejoin(port, chess_dir):
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)  # fresh store: nothing to sync yet
    c.send(NEWGAME)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 0
    c.move("e2", "e4")
    c.expect_move("e2", "e4")
    her_move(chess_dir, "guest-001", "e5")
    c.expect_move("e7", "e5")
    c.move("g1", "f3")
    c.expect_move("g1", "f3")
    her_move(chess_dir, "guest-001", "Nc6")
    c.expect_move("b8", "c6")
    hard_reset(c.sock)
    time.sleep(0.3)

    c2 = Client(port)
    c2.join()
    c2.expect(PLAYER)
    c2.expect(OPPONENT_JOINED)
    f = c2.expect(TEAM)
    assert f.get(1, 0) == 0, "rejoin must deal the user their own colour"
    for frm, to in [("e2", "e4"), ("e7", "e5"), ("g1", "f3"), ("b8", "c6")]:
        c2.expect_move(frm, to)
    ok("the rejoin was synced the full position at once, no NewGame click")

    games = sorted(os.listdir(Path(chess_dir) / "games"))
    assert games == ["guest-001.json"], f"rejoin touched the store: {games}"
    assert game_moves(chess_dir, "guest-001") == \
        ["e2e4", "e7e5", "g1f3", "b8c6"]
    ok("rejoining created nothing and reset nothing")

    c2.move("f1", "b5")  # white to move after four plies; the store agrees
    c2.expect_move("f1", "b5")
    assert game_moves(chess_dir, "guest-001")[-1] == "f1b5"
    ok("side to move survived the rejoin: the user's Bb5 was accepted")


def s_postkill(port, chess_dir):
    # The bridge was SIGKILLed after s_rejoin; this is the fresh serve.
    c = Client(port)
    c.join()
    c.expect(PLAYER)
    c.expect(OPPONENT_JOINED)
    f = c.expect(TEAM)
    assert f.get(1, 0) == 0
    for frm, to in [("e2", "e4"), ("e7", "e5"), ("g1", "f3"), ("b8", "c6"),
                    ("f1", "b5")]:
        c.expect_move(frm, to)
    ok("SIGKILL then restart: the same position came back on join")

    games = sorted(os.listdir(Path(chess_dir) / "games"))
    assert games == ["guest-001.json"], f"restart changed the store: {games}"
    ok("same game id, and no second game appeared")

    her_move(chess_dir, "guest-001", "a6")  # her turn after Bb5
    c.expect_move("a7", "a6")
    c.move("b5", "a4")
    c.expect_move("b5", "a4")
    assert game_moves(chess_dir, "guest-001")[-2:] == ["a7a6", "b5a4"]
    ok("play continued in the same game after the restart")


def main():
    what = sys.argv[1]
    if what == "seed":
        chess_dir, gid, opponent, my_side = sys.argv[2:6]
        seed(chess_dir, gid, opponent, my_side, sys.argv[6:])
        return
    port = int(sys.argv[2])
    rest = sys.argv[3:]
    {"http": s_http, "fresh": s_fresh, "resume": s_resume,
     "special": s_special, "promote": s_promote, "mate": s_mate,
     "poller_end": s_poller_end, "reset": s_reset, "rejoin": s_rejoin,
     "postkill": s_postkill, "reflex": s_reflex}[what](port, *rest)


if __name__ == "__main__":
    main()
