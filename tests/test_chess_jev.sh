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
      not any("CHECKMATE" in lcrit[u] for u in ("g7g6", "f8e8", "b4c3")))
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
contains "$PYOUT" "in-check-field: True" \
    && ok "the state says so when she stands in check" \
    || fail "in-check" "$(printf '%s\n' "$PYOUT" | grep in-check-field)"
contains "$PYOUT" "no-check-field-when-quiet: True" \
    && ok "and says nothing about check on a quiet board" \
    || fail "quiet check" "$(printf '%s\n' "$PYOUT" | grep no-check-field)"
contains "$PYOUT" "promotion-tagged: True" \
    && ok "a promoting candidate says so on its description" \
    || fail "promotion tag" "$(printf '%s\n' "$PYOUT" | grep promotion-tagged)"

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
