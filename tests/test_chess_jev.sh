#!/bin/bash
# The TypeSafe backend — specs/chessweb.md rule 16h.
# Run: bash tests/test_chess_jev.sh
#
# The contract under test, all of it against a loopback stub server (no
# live TypeSafe call anywhere; the key used here is a made-up string that
# never leaves the sandbox):
#
#   1. A routed jev offer yields exactly one attempt: the typesafe helper
#      subprocess, carrying the resolved model on --model, and nothing
#      else — no Claude, no codex. The bare "jev" spelling resolves to
#      jev-latest. Without TYPESAFE_API_KEY the routed offer yields no
#      attempt at all, named out loud; an env-chain jev name falls through
#      to the Claude walk at the fallback model after the one typesafe
#      attempt.
#   2. The request body is rule 16h's shape: one Choice question whose
#      criteria keys are EXACTLY the legal moves, the machine's verdicts in
#      the option descriptions, and a state carrying the FEN, the pieces in
#      words, the movetext, the note, and the position memory's section —
#      the board-state memory demonstrably rides the request, and an
#      endorsed move's description says so.
#   3. End to end through the mover: the stub's choice lands on the board
#      as a posted move; the request went out with the Bearer key and the
#      routed model; usage and confidence come back on the ledger-shaped
#      result object.
#   4. Transport honesty: a 429 is retried inside the attempt and the move
#      still lands; a 401 fails the attempt with "not logged in" in the
#      cause, unplayed, no substitute.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "SKIP: no chess venv at $VENV — the mover needs python-chess"
    exit 0
fi

PYOUT="$(env \
    DESKCRAB_CHESS_DIR="$T/chess-games" \
    DESKCRAB_CHESS_MEMORY_PROMPT=0 DESKCRAB_CHESS_SIMILAR=0 \
    ACCOUNT_STATE_FILE="$T/account-state" \
    TYPESAFE_HTTP_TIMEOUT=5 \
    "$PY" -B - <<PYEOF
import http.server, json, os, sys, threading, time
sys.path.insert(0, "$REPO/lib")
import chess, chess_mover

seen = []
MODE = {"value": "ok", "flaky_left": 0}

class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, payload, headers=()):
        body = json.dumps(payload).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append({"path": self.path,
                     "auth": self.headers.get("Authorization"),
                     "body": body})
        if MODE["value"] == "unauthorized":
            self._send(401, {"error": "invalid api key"})
            return
        if MODE["value"] == "flaky" and MODE["flaky_left"] > 0:
            MODE["flaky_left"] -= 1
            self._send(429, {"error": "rate limited"},
                       headers=[("Retry-After", "0")])
            return
        crit = body["questions"]["move"]["criteria"]
        choice = "e2e4" if "e2e4" in crit else sorted(crit)[0]
        self._send(200, {
            "model": "jev-1.13.0",
            "answers": {"move": {"type": "choice", "choice": choice,
                                 "probabilities": {choice: 0.9},
                                 "confidence": 0.87}},
            "usage": {"input_tokens": 812, "output_tokens": 40}})

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
threading.Thread(target=server.serve_forever, daemon=True).start()
os.environ["TYPESAFE_API_URL"] = ("http://127.0.0.1:%d/systemone"
                                  % server.server_address[1])
os.environ["TYPESAFE_API_KEY"] = "stub-key-never-real"

alerts, played = [], []
m = chess_mover.Mover(lambda job, mv: played.append((job["gid"], mv.uci())) or True,
                      log=lambda *a, **k: None,
                      metric=lambda stage, detail="": None,
                      alert=lambda msg: alerts.append(msg))

# -- 1. the attempt walk ---------------------------------------------------
att = list(m._attempts("low", False, "jev"))
print("routed-labels:", " ".join(l for l, _, _ in att))
print("routed-helper:", os.path.basename(att[0][1][1]) if att else "NONE")
print("routed-model:",
      att[0][1][att[0][1].index("--model") + 1] if att else "NONE")

os.environ["DESKCRAB_CHESS_MOVER_MODEL"] = "jev-latest"
os.environ["CODEX_FALLBACK_MODEL"] = "haiku"
chain = list(m._attempts("low", False, None))
print("chain-labels:", " ".join(l for l, _, _ in chain))
claude_cmds = [cmd for l, cmd, _ in chain if l.startswith("account")]
print("chain-fallback-model:",
      claude_cmds[0][claude_cmds[0].index("--model") + 1]
      if claude_cmds else "NONE")
del os.environ["DESKCRAB_CHESS_MOVER_MODEL"]
del os.environ["CODEX_FALLBACK_MODEL"]

key = os.environ.pop("TYPESAFE_API_KEY")
nokey = list(m._attempts("low", False, "jev-latest"))
print("nokey-attempts:", len(nokey))
print("nokey-alerted:", any("TYPESAFE_API_KEY" in a and "no substitute" in a
                            for a in alerts))
os.environ["TYPESAFE_API_KEY"] = key

# -- 2. the request body ---------------------------------------------------
board = chess.Board()
job = {"key": "jev-1", "gid": "jev-1", "ply": 2, "fen": chess.STARTING_FEN,
       "side": "white", "opponent": "tester", "history": "1. (none)",
       "note": "the bridge says hi", "model": "jev-latest",
       "effort": "low", "t0": time.time()}
real_memory = chess_mover.memory_facts
chess_mover.memory_facts = lambda b: {
    "declined": [],
    "similar": [{"similarity": 0.91, "san": "Nf3", "colour": "white",
                 "game_id": "game-1", "ply": 9, "move": "g1f3",
                 "fen": chess.STARTING_FEN,
                 "n": 1, "wins": 1, "draws": 0, "losses": 0}],
    "endorsed": {"g1f3"}, "stamp": None}
try:
    req = chess_mover.jev_request(job, board)
finally:
    chess_mover.memory_facts = real_memory
q = req["questions"]["move"]
legal = sorted(mv.uci() for mv in board.legal_moves)
print("q-type:", q["type"])
print("criteria-are-the-whitelist:", sorted(q["criteria"]) == legal)
print("memory-in-state:",
      any(isinstance(e, dict) and e.get("similarity") == 0.91
          and e.get("played") == "Nf3 as white"
          and e.get("result") == "won that game"
          and "king on e1" in e.get("board_it_was_played_on",
                                    {}).get("white", "").lower()
          for e in req["state"]["position_memory"]))
print("endorsement-in-option:", "memory endorses" in q["criteria"]["g1f3"])
print("fen-in-state:", req["state"]["position_fen"] == chess.STARTING_FEN)
print("pieces-in-words:",
      "king on e1" in req["state"]["pieces_on_the_board"]["white"].lower())
print("note-in-state:", req["state"].get("note") == "the bridge says hi")
print("standing-in-state:",
      req["state"].get(
          "pieces_of_yours_the_opponent_can_win_where_they_stand") == "none")

# -- 2b. mate, check, and promotion awareness (rule 16h) ---------------------
mate_board = chess.Board(
    "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2")
mreq = chess_mover.jev_request(dict(job, side="black",
                                    fen=mate_board.fen()), mate_board)
print("mate-marked:",
      mreq["questions"]["move"]["criteria"]["d8h4"]
      == "Qh4# — CHECKMATE: this move ends the game in your favour")
print("mate-rule-in-instructions:",
      "CHECKMATE wins the game immediately"
      in mreq["questions"]["move"]["instructions"])
print("pawn-rule-in-instructions:",
      "passed pawns toward promotion"
      in mreq["questions"]["move"]["instructions"])
# The lost game: a candidate that drops a pawn AND allows mate in one used
# to skip the reply scan and read as the cheapest option on the board.
lost_board = chess.Board(
    "rn1q1rk1/ppp2ppp/4pB2/3p2N1/1b1P3P/2PQP3/PP3PP1/RN2K2R b KQ - 0 11")
lreq = chess_mover.jev_request(dict(job, side="black",
                                    fen=lost_board.fen()), lost_board)
lcrit = lreq["questions"]["move"]["criteria"]
print("mate-named-on-losing-candidate:",
      lcrit["e6e5"] == "e5 — reply Qxh7# is CHECKMATE")
print("no-memory-endorsement-into-mate:",
      "memory" not in lcrit["e6e5"])
print("survivable-moves-unmarked:",
      not any("CHECKMATE" in lcrit[u] for u in ("g7g6", "b4c3")))
# The second ply (browser-064): 11...Re8 loses nothing where it lands and has
# no mating reply one ply deep, but 12.Qxh7+ Kf8 13.Qh8# is forced, so it is
# named as a mate in two rather than printed safe.
print("mate-in-two-named:",
      lcrit["f8e8"] == ("Re8 — reply Qxh7+ FORCES CHECKMATE next move, "
                        "whatever you answer"))
print("no-memory-endorsement-into-mate-in-two:", "memory" not in lcrit["f8e8"])
# A quiet opening position has no forced mate in it, so the label stays off
# the board entirely when nothing is there.
print("no-mate-in-two-in-a-quiet-position:",
      not any("FORCES CHECKMATE" in d
              for d in req["questions"]["move"]["criteria"].values()))
check_board = chess.Board(
    "rnbqkbnr/ppppp1pp/8/5p1Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2")
creq = chess_mover.jev_request(dict(job, side="black",
                                    fen=check_board.fen()), check_board)
print("in-check-field:", "you_are_in_check" in creq["state"])
print("no-check-field-when-quiet:", "you_are_in_check" not in req["state"])
promo_board = chess.Board("8/5P1k/8/8/8/8/8/K7 w - - 0 1")
preq = chess_mover.jev_request(dict(job, side="white",
                                    fen=promo_board.fen()), promo_board)
print("promotion-tagged:",
      "promotes this pawn"
      in preq["questions"]["move"]["criteria"]["f7f8q"])

# -- 2c. repetition (the drawn-won-game amendment) ---------------------------
# The real shuffle: a queen and a rook up, the king stepping between two
# squares while a rook checks, until the fifth repetition drew the game.
rep_hist = ("1. d4 d5 2. Bf4 Nf6 3. e3 Nc6 4. Bd3 Bg4 5. Nf3 Ne4 6. h3 Bh5 "
            "7. Nbd2 Nd6 8. Ng5 Bg6 9. Bb5 e6 10. c3 h6 11. Ngf3 Nxb5 "
            "12. Qa4 Nd6 13. Nb3 Ne4 14. Nc5 Nd6 15. Nxb7 Nxb7 16. Qxc6+ Qd7 "
            "17. Qxb7 Rc8 18. Qxa7 Be4 19. a4 f6 20. Qb7 Bd3 21. a5 Ba6 "
            "22. Qxa6 Ra8 23. Qb7 Rc8 24. a6 c6 25. a7 Qxb7 26. O-O Ra8 "
            "27. Rfb1 Rxa7 28. Rxa7 Qxa7 29. Nd2 c5 30. dxc5 Qxc5 31. Ra1 Qb5 "
            "32. Ra8+ Kd7 33. Nb1 Qxb2 34. Ra7+ Kc6 35. Ra6+ Kd7 36. Ra7+ "
            "Kc6 37. Ra6+ Kd7 38. Ra7+")
rep_fen = "5b1r/R2k2p1/4pp1p/3p4/5B2/2P1P2P/1q3PP1/1N4K1 b - - 13 38"
rep_board = chess.Board(rep_fen)
rjob = dict(job, side="black", fen=rep_fen, history=rep_hist)
rcrit = chess_mover.jev_request(rjob, rep_board)["questions"]["move"]["criteria"]
print("repeat-named:", "REPEATS a position this game has already stood in 2"
      in rcrit["d7c6"])
print("repeat-costs-the-win:", "throws that away" in rcrit["d7c6"])
print("escapes-unmarked:",
      not any("REPEATS" in rcrit[u] for u in ("d7e8", "d7d8", "d7c8")))
print("repeat-rule-in-instructions:",
      "never pick a repeating option"
      in chess_mover.jev_request(rjob,
                                 rep_board)["questions"]["move"]["instructions"])
# The fifth occurrence ends the game, and the option says exactly that.
fifth_hist = rep_hist + (" Kc6 39. Ra6+ Kd7 40. Ra7+ Kc6 41. Ra6+ Kd7 "
                         "42. Ra7+")
fifth_fen = "5b1r/R2k2p1/4pp1p/3p4/5B2/2P1P2P/1q3PP1/1N4K1 b - - 17 42"
fcrit = chess_mover.jev_request(
    dict(job, side="black", fen=fifth_fen, history=fifth_hist),
    chess.Board(fifth_fen))["questions"]["move"]["criteria"]
print("fifth-ends-it:", "ends the game drawn on the spot" in fcrit["d7c6"])
# A movetext that will not replay, or belongs to another game, says nothing.
print("junk-history-silent:", not any(
    "REPEATS" in d for d in chess_mover.jev_request(
        dict(rjob, history="1. zz9 qq"),
        rep_board)["questions"]["move"]["criteria"].values()))
print("foreign-history-silent:", not any(
    "REPEATS" in d for d in chess_mover.jev_request(
        dict(rjob, history="1. e4 e5 2. Nf3"),
        rep_board)["questions"]["move"]["criteria"].values()))

# -- 2d. the quiet-move budget ----------------------------------------------
# chess-mover-amendment.md, "The quiet-move budget is counted". A stored pool
# is built here rather than borrowed from the live store, so the record the
# clause quotes is known exactly: twelve games with at most one quiet
# queen/pawn move in moves 11-15 (8 won, 4 lost) and twelve with several
# (2 won, 10 lost). Bench self-play is written in too, with the opposite
# results, to prove it is excluded from the count.
import pathlib, random


def build_game(quiet_in_window, my_side, won, bench=False, seed=0):
    """A replayable game whose window carries (or avoids) quiet q/p moves."""
    rng = random.Random(seed)
    mine = chess.WHITE if my_side == "white" else chess.BLACK
    board, moves, made = chess.Board(), [], 0
    while board.fullmove_number <= 17 and not board.is_game_over():
        legal = list(board.legal_moves)
        rng.shuffle(legal)
        want = None
        if board.turn == mine and board.fullmove_number in range(11, 16):
            want = made < quiet_in_window
        pick = None
        for m in legal:
            quiet = chess_mover.is_quiet_qp(board, m)
            if want is not None and quiet != want:
                continue
            if board.is_capture(m) or board.gives_check(m):
                continue
            pick = m
            break
        if pick is None:
            pick = legal[0]
        if (board.turn == mine and board.fullmove_number in range(11, 16)
                and chess_mover.is_quiet_qp(board, pick)):
            made += 1
        moves.append(pick.uci())
        board.push(pick)
    loser = my_side if not won else ("black" if mine == chess.WHITE
                                     else "white")
    return {"my_side": my_side, "opponent": "bench" if bench else "browser",
            "bench": bench, "moves": moves, "resigned_by": loser}, made


gdir = pathlib.Path(os.environ["DESKCRAB_CHESS_DIR"]) / "games"
gdir.mkdir(parents=True, exist_ok=True)
built = {"low": [0, 0], "high": [0, 0]}
plan = ([("low", True)] * 8 + [("low", False)] * 4
        + [("high", True)] * 2 + [("high", False)] * 10)
for i, (bucket, won) in enumerate(plan):
    want = 1 if bucket == "low" else 3
    side = "white" if i % 2 == 0 else "black"
    g, made = build_game(want, side, won, seed=i)
    if (made <= 1) != (bucket == "low"):
        print("FIXTURE-MISBUILT:", bucket, made)
    built[bucket][0 if won else 1] += 1
    (gdir / f"quiet-{i:02d}.json").write_text(json.dumps(g))
# Bench self-play, the pool that must not be counted: the results reversed.
for i, (bucket, won) in enumerate(plan):
    g, _ = build_game(1 if bucket == "low" else 3,
                      "white" if i % 2 else "black", not won,
                      bench=True, seed=100 + i)
    (gdir / f"bench-{i:02d}.json").write_text(json.dumps(g))
print("quiet-fixture-built:", built)
print("quiet-tally:", chess_mover.quiet_tally(refresh=True))

# A real position at full-move 13 with two quiet queen/pawn moves behind it.
q_line = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "d2d3", "f8c5",
          "c2c3", "d7d6", "b1d2", "e8g8", "e1g1", "a7a6", "a2a4", "b7b6",
          "d1e2", "c8e6", "e2e1", "d8d7", "e1e2", "f8e8", "h2h3", "h7h6"]


def movetext(ucis):
    b, out = chess.Board(), []
    for u in ucis:
        mv = chess.Move.from_uci(u)
        if b.turn == chess.WHITE:
            out.append(f"{b.fullmove_number}.")
        out.append(b.san(mv))
        b.push(mv)
    return " ".join(out), b


q_hist, q_board = movetext(q_line)
qjob = dict(job, side="white", fen=q_board.fen(), history=q_hist)
qcrit = chess_mover.jev_request(qjob, q_board)["questions"]["move"]["criteria"]
print("quiet-already:", chess_mover.quiet_already(qjob, q_board))
print("quiet-third-named:",
      "would be the third quiet queen/pawn move of moves 11-15"
      in qcrit["e2e1"])
print("quiet-record-quoted:",
      "at most one here: 8 wins to 4 losses; with two or more: 2 to 10"
      in qcrit["e2e1"])
print("quiet-on-a-pawn-push:",
      "quiet queen/pawn move" in qcrit["a4a5"])
print("quiet-not-on-a-knight:",
      "quiet queen/pawn move" not in qcrit["f3h4"])
print("quiet-not-on-a-capture:",
      "quiet queen/pawn move" not in qcrit["c4e6"])
# A queen move that gives check is not quiet, however peaceful it looks.
chk_fen = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 6 13"
chk_board = chess.Board(chk_fen)
print("quiet-check-excluded:", not chess_mover.is_quiet_qp(
    chk_board, chess.Move.from_uci("c4f7")))
# Outside the window there is no clause at all, the same position notwithstanding.
early = q_line[:16]
e_hist, e_board = movetext(early)
ecrit = chess_mover.jev_request(
    dict(job, side="white", fen=e_board.fen(), history=e_hist),
    e_board)["questions"]["move"]["criteria"]
print("quiet-before-window:", e_board.fullmove_number, not any(
    "quiet queen/pawn move" in d for d in ecrit.values()))
late = q_line + ["d2f1", "e6f5", "f1g3", "f5g6", "g1h2", "g8h8", "h2g1",
                 "h8g8"]
l_hist, l_board = movetext(late)
lcrit = chess_mover.jev_request(
    dict(job, side="white", fen=l_board.fen(), history=l_hist),
    l_board)["questions"]["move"]["criteria"]
print("quiet-after-window:", l_board.fullmove_number, not any(
    "quiet queen/pawn move" in d for d in lcrit.values()))
# An unreplayable or foreign movetext is a missing clause, never a wrong one.
print("quiet-junk-history-silent:", not any(
    "quiet queen/pawn move" in d for d in chess_mover.jev_request(
        dict(qjob, history="1. zz9 qq"),
        q_board)["questions"]["move"]["criteria"].values()))
print("quiet-foreign-history-silent:", not any(
    "quiet queen/pawn move" in d for d in chess_mover.jev_request(
        dict(qjob, history="1. e4 e5 2. Nf3"),
        q_board)["questions"]["move"]["criteria"].values()))
print("quiet-legend-in-instructions:",
      "quiet queen/pawn move of moves 11-15"
      in chess_mover.jev_request(
          qjob, q_board)["questions"]["move"]["instructions"])
# Too small a pool says nothing rather than quoting a record of two games.
thin = pathlib.Path(os.environ["DESKCRAB_CHESS_DIR"]) / "thin"
(thin / "games").mkdir(parents=True, exist_ok=True)
for i, (bucket, won) in enumerate(plan[:4]):
    g, _ = build_game(1 if bucket == "low" else 3, "white", won, seed=200 + i)
    (thin / "games" / f"g{i}.json").write_text(json.dumps(g))
_real_dir = os.environ["DESKCRAB_CHESS_DIR"]
os.environ["DESKCRAB_CHESS_DIR"] = str(thin)
print("quiet-thin-pool-silent:", not any(
    "quiet queen/pawn move" in d for d in chess_mover.jev_request(
        qjob, q_board)["questions"]["move"]["criteria"].values()))
os.environ["DESKCRAB_CHESS_DIR"] = _real_dir

# -- 3. end to end through the mover ----------------------------------------
outcome, why = m._answer(job)
print("e2e-outcome:", outcome)
print("e2e-played:", played)
print("e2e-auth:", seen[-1]["auth"])
print("e2e-model-sent:", seen[-1]["body"].get("model"))

# -- 4. transport honesty ----------------------------------------------------
MODE["value"], MODE["flaky_left"] = "flaky", 1
before = len(seen)
outcome, why = m._answer(dict(job, key="jev-2", gid="jev-2"))
print("flaky-outcome:", outcome)
print("flaky-calls:", len(seen) - before)

MODE["value"] = "unauthorized"
outcome, why = m._answer(dict(job, key="jev-3", gid="jev-3"))
print("auth-outcome:", outcome)
print("auth-why-visible:", "not logged in" in (why or "").lower())
print("auth-played-count:", len(played))
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

echo
echo "the attempt walk (rule 16h identity and fallback):"
contains "$PYOUT" "routed-labels: typesafe" \
    && ok "a routed jev offer is exactly one typesafe attempt, nothing else" \
    || fail "routed labels" "$(printf '%s\n' "$PYOUT" | grep routed-labels)"
contains "$PYOUT" "routed-helper: typesafe_move.py" \
    && ok "the attempt is the helper subprocess" \
    || fail "routed helper" "$(printf '%s\n' "$PYOUT" | grep routed-helper)"
contains "$PYOUT" "routed-model: jev-latest" \
    && ok "the bare jev spelling resolves to jev-latest on the argv" \
    || fail "routed model" "$(printf '%s\n' "$PYOUT" | grep routed-model)"
contains "$PYOUT" "chain-labels: typesafe account 1" \
    && ok "an env-chain jev tries typesafe once, then the Claude walk" \
    || fail "chain labels" "$(printf '%s\n' "$PYOUT" | grep chain-labels)"
contains "$PYOUT" "chain-fallback-model: haiku" \
    && ok "the Claude walk runs at the configured fallback model" \
    || fail "chain fallback" "$(printf '%s\n' "$PYOUT" | grep chain-fallback)"
contains "$PYOUT" "nokey-attempts: 0" \
    && ok "a routed jev offer with no key yields no attempt at all" \
    || fail "nokey attempts" "$(printf '%s\n' "$PYOUT" | grep nokey-attempts)"
contains "$PYOUT" "nokey-alerted: True" \
    && ok "and the missing key is named out loud, no substitute engine" \
    || fail "nokey alert" "$(printf '%s\n' "$PYOUT" | grep nokey-alerted)"

echo
echo "the request body (rule 16h shape):"
contains "$PYOUT" "q-type: choice" \
    && ok "the one question is a Choice" || fail "question type" "$(printf '%s\n' "$PYOUT" | grep q-type)"
contains "$PYOUT" "criteria-are-the-whitelist: True" \
    && ok "the options ARE the legal moves, exactly" \
    || fail "criteria whitelist" "$(printf '%s\n' "$PYOUT" | grep criteria-are)"
contains "$PYOUT" "memory-in-state: True" \
    && ok "the board-state memory section rides the request" \
    || fail "memory in state" "$(printf '%s\n' "$PYOUT" | grep memory-in-state)"
contains "$PYOUT" "endorsement-in-option: True" \
    && ok "an endorsed move's description carries the memory's record" \
    || fail "endorsement" "$(printf '%s\n' "$PYOUT" | grep endorsement)"
contains "$PYOUT" "fen-in-state: True" \
    && ok "the FEN rides the state" || fail "fen" "$(printf '%s\n' "$PYOUT" | grep fen-in-state)"
contains "$PYOUT" "pieces-in-words: True" \
    && ok "the pieces also ride in words, not encoding alone" \
    || fail "pieces in words" "$(printf '%s\n' "$PYOUT" | grep pieces-in-words)"
contains "$PYOUT" "note-in-state: True" \
    && ok "the job's note rides the state" || fail "note" "$(printf '%s\n' "$PYOUT" | grep note-in-state)"
contains "$PYOUT" "standing-in-state: True" \
    && ok "the standing sweep renders its affirmative all-clear" \
    || fail "standing" "$(printf '%s\n' "$PYOUT" | grep standing-in-state)"

echo
echo "mate, check, and promotion awareness (rule 16h):"
contains "$PYOUT" "mate-marked: True" \
    && ok "a candidate that IS checkmate is marked as the immediate win" \
    || fail "mate marking" "$(printf '%s\n' "$PYOUT" | grep mate-marked)"
contains "$PYOUT" "mate-rule-in-instructions: True" \
    && ok "the instructions carry the mate rule" \
    || fail "mate rule" "$(printf '%s\n' "$PYOUT" | grep mate-rule)"
contains "$PYOUT" "pawn-rule-in-instructions: True" \
    && ok "the instructions carry the passed-pawn urgencies both ways" \
    || fail "pawn rule" "$(printf '%s\n' "$PYOUT" | grep pawn-rule)"
contains "$PYOUT" "mate-named-on-losing-candidate: True" \
    && ok "a candidate that loses material is still swept for mating replies" \
    || fail "mate on losing candidate" \
        "$(printf '%s\n' "$PYOUT" | grep mate-named-on-losing)"
contains "$PYOUT" "no-memory-endorsement-into-mate: True" \
    && ok "and no memory record endorses a move that walks into mate" \
    || fail "endorsement into mate" \
        "$(printf '%s\n' "$PYOUT" | grep no-memory-endorsement)"
contains "$PYOUT" "survivable-moves-unmarked: True" \
    && ok "the moves that do survive carry no mate label" \
    || fail "survivable" "$(printf '%s\n' "$PYOUT" | grep survivable-moves)"
contains "$PYOUT" "mate-in-two-named: True" \
    && ok "a forced mate one move further out is named, not printed safe" \
    || fail "mate in two" "$(printf '%s\n' "$PYOUT" | grep mate-in-two-named)"
contains "$PYOUT" "no-memory-endorsement-into-mate-in-two: True" \
    && ok "and no memory record endorses a move mated in two" \
    || fail "endorsement into mate in two" \
        "$(printf '%s\n' "$PYOUT" | grep no-memory-endorsement-into-mate-in-two)"
contains "$PYOUT" "no-mate-in-two-in-a-quiet-position: True" \
    && ok "a quiet position carries no forced-mate label at all" \
    || fail "quiet position mate label" \
        "$(printf '%s\n' "$PYOUT" | grep no-mate-in-two-in-a-quiet)"
contains "$PYOUT" "in-check-field: True" \
    && ok "the state says so when she stands in check" \
    || fail "in-check" "$(printf '%s\n' "$PYOUT" | grep in-check-field)"
contains "$PYOUT" "no-check-field-when-quiet: True" \
    && ok "and says nothing about check on a quiet board" \
    || fail "quiet check" "$(printf '%s\n' "$PYOUT" | grep no-check-field)"
contains "$PYOUT" "promotion-tagged: True" \
    && ok "a promoting candidate says so on its description" \
    || fail "promotion tag" "$(printf '%s\n' "$PYOUT" | grep promotion-tagged)"

contains "$PYOUT" "repeat-named: True" \
    && ok "an option that returns to a stood-in position says so, with the count" \
    || fail "repeat named" "$(printf '%s\n' "$PYOUT" | grep repeat-named)"
contains "$PYOUT" "repeat-costs-the-win: True" \
    && ok "and says what repeating costs her while she is ahead" \
    || fail "repeat cost" "$(printf '%s\n' "$PYOUT" | grep repeat-costs)"
contains "$PYOUT" "escapes-unmarked: True" \
    && ok "the moves that leave the repetition carry no such clause" \
    || fail "escapes" "$(printf '%s\n' "$PYOUT" | grep escapes-unmarked)"
contains "$PYOUT" "repeat-rule-in-instructions: True" \
    && ok "the instructions forbid repeating while ahead" \
    || fail "repeat rule" "$(printf '%s\n' "$PYOUT" | grep repeat-rule)"
contains "$PYOUT" "fifth-ends-it: True" \
    && ok "the fifth occurrence is named as ending the game drawn" \
    || fail "fifth" "$(printf '%s\n' "$PYOUT" | grep fifth-ends-it)"
contains "$PYOUT" "junk-history-silent: True" \
    && ok "an unreplayable movetext produces no clause rather than a wrong one" \
    || fail "junk history" "$(printf '%s\n' "$PYOUT" | grep junk-history)"
contains "$PYOUT" "foreign-history-silent: True" \
    && ok "and neither does a movetext from some other game" \
    || fail "foreign history" "$(printf '%s\n' "$PYOUT" | grep foreign-history)"

echo
echo "the quiet-move budget (chess-mover-amendment.md):"
contains "$PYOUT" "FIXTURE-MISBUILT" \
    && fail "fixture" "$(printf '%s\n' "$PYOUT" | grep FIXTURE-MISBUILT)" \
    || ok "the fixture pool landed in the buckets it was built for"
contains "$PYOUT" "quiet-tally: {'low': (8, 4), 'high': (2, 10)}" \
    && ok "the tally counts real games only — the bench pool is excluded" \
    || fail "tally" "$(printf '%s\n' "$PYOUT" | grep quiet-tally)"
contains "$PYOUT" "quiet-already: 2" \
    && ok "the window count comes from the movetext, not the position" \
    || fail "already" "$(printf '%s\n' "$PYOUT" | grep quiet-already)"
contains "$PYOUT" "quiet-third-named: True" \
    && ok "a quiet queen move says which one of the window it would be" \
    || fail "third" "$(printf '%s\n' "$PYOUT" | grep quiet-third-named)"
contains "$PYOUT" "quiet-record-quoted: True" \
    && ok "and carries the stored record at that count, both buckets" \
    || fail "record" "$(printf '%s\n' "$PYOUT" | grep quiet-record-quoted)"
contains "$PYOUT" "quiet-on-a-pawn-push: True" \
    && ok "a quiet pawn push is counted the same as a queen move" \
    || fail "pawn push" "$(printf '%s\n' "$PYOUT" | grep quiet-on-a-pawn)"
contains "$PYOUT" "quiet-not-on-a-knight: True" \
    && ok "a knight move carries no clause" \
    || fail "knight" "$(printf '%s\n' "$PYOUT" | grep quiet-not-on-a-knight)"
contains "$PYOUT" "quiet-not-on-a-capture: True" \
    && ok "nor does a capture" \
    || fail "capture" "$(printf '%s\n' "$PYOUT" | grep quiet-not-on-a-capture)"
contains "$PYOUT" "quiet-check-excluded: True" \
    && ok "nor a queen move that gives check" \
    || fail "check" "$(printf '%s\n' "$PYOUT" | grep quiet-check-excluded)"
contains "$PYOUT" "quiet-before-window: 9 True" \
    && ok "before move 11 the clause is absent entirely" \
    || fail "before window" "$(printf '%s\n' "$PYOUT" | grep quiet-before-window)"
contains "$PYOUT" "quiet-after-window: 17 True" \
    && ok "and after move 15 it is absent again" \
    || fail "after window" "$(printf '%s\n' "$PYOUT" | grep quiet-after-window)"
contains "$PYOUT" "quiet-junk-history-silent: True" \
    && ok "an unreplayable movetext yields no budget clause" \
    || fail "quiet junk" "$(printf '%s\n' "$PYOUT" | grep quiet-junk-history)"
contains "$PYOUT" "quiet-foreign-history-silent: True" \
    && ok "neither does another game's movetext" \
    || fail "quiet foreign" "$(printf '%s\n' "$PYOUT" | grep quiet-foreign-history)"
contains "$PYOUT" "quiet-thin-pool-silent: True" \
    && ok "too small a pool says nothing rather than quoting four games" \
    || fail "thin pool" "$(printf '%s\n' "$PYOUT" | grep quiet-thin-pool)"
contains "$PYOUT" "quiet-legend-in-instructions: True" \
    && ok "the legend is stated once, in the instructions" \
    || fail "quiet legend" "$(printf '%s\n' "$PYOUT" | grep quiet-legend)"

echo
echo "end to end through the mover:"
contains "$PYOUT" "e2e-outcome: posted" \
    && ok "the stub's choice landed as a posted move" \
    || fail "e2e outcome" "$(printf '%s\n' "$PYOUT" | grep e2e-outcome)"
contains "$PYOUT" "e2e-played: [('jev-1', 'e2e4')]" \
    && ok "the posted move is the answer's own choice" \
    || fail "e2e played" "$(printf '%s\n' "$PYOUT" | grep e2e-played)"
contains "$PYOUT" "e2e-auth: Bearer stub-key-never-real" \
    && ok "the key rode the Authorization header, never an argv" \
    || fail "e2e auth" "$(printf '%s\n' "$PYOUT" | grep e2e-auth)"
contains "$PYOUT" "e2e-model-sent: jev-latest" \
    && ok "the routed model name went out on the request" \
    || fail "e2e model" "$(printf '%s\n' "$PYOUT" | grep e2e-model-sent)"

echo
echo "transport honesty:"
contains "$PYOUT" "flaky-outcome: posted" \
    && ok "a 429 is retried inside the attempt and the move still lands" \
    || fail "flaky outcome" "$(printf '%s\n' "$PYOUT" | grep flaky-outcome)"
contains "$PYOUT" "flaky-calls: 2" \
    && ok "exactly one retry — the refusal plus the answer" \
    || fail "flaky calls" "$(printf '%s\n' "$PYOUT" | grep flaky-calls)"
contains "$PYOUT" "auth-outcome: failed" \
    && ok "a refused key fails the attempt, unplayed, no substitute" \
    || fail "auth outcome" "$(printf '%s\n' "$PYOUT" | grep auth-outcome)"
contains "$PYOUT" "auth-why-visible: True" \
    && ok "the cause names the login, not whatever printed last" \
    || fail "auth why" "$(printf '%s\n' "$PYOUT" | grep auth-why)"
contains "$PYOUT" "auth-played-count: 2" \
    && ok "the board took only the two honest moves" \
    || fail "auth played" "$(printf '%s\n' "$PYOUT" | grep auth-played)"
