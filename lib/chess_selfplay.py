#!/usr/bin/env python3
"""chess_selfplay: the overnight grind, budgeted. specs/chess-selfplay.md.

Two mover instances play each other so the pattern store learns while nobody
is at the board. One bounded chunk per invocation — the caller loops. Each
chunk:
  - refuses to run while a live browser game is hot (a person may be at the
    board, and the resident mover owns the accounts);
  - plays moves on the current self-play game through the SAME path a real
    game uses: reflex memory first, the mover otherwise, the answer validated
    against the store as it stands and written through chess_cli.save_game —
    the choke point that feeds the pattern store when a game finishes;
  - claims rules-legal draws (threefold / fifty-move) so grinding never
    shuffles forever, and agrees a draw at a hard ply cap as backstop;
  - exits before its chunk budget so the calling shell never has to kill it.

The economics are the point of this file's existence (specs/chess-selfplay.md,
the 2026-08-15 incident): the mover binds self-play to its OWN model knob
(DESKCRAB_CHESS_SELFPLAY_MODEL, default sonnet — never the real-game knob),
and the nightly move budget is checked here in the loop BEFORE a position is
submitted, with the mover's refusal as the backstop. When the budget is spent
the chunk stops cleanly — status `budget-spent` — and books nothing more.

Never touches browser-* games. Never books wakes, never notifies, never
speaks. State is the game files themselves; this process holds nothing that
matters across chunks.

Usage: chess_selfplay.py [--budget SECONDS] [--games N] [--deadline HH:MM]
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# The effort dials, set before the modules that read them at import time:
# the grind thinks at the cheap tier unless the caller says otherwise.
os.environ.setdefault("DESKCRAB_CHESS_EFFORT_QUIET", "low")
os.environ.setdefault("DESKCRAB_CHESS_EFFORT_SHARP", "low")
os.environ.setdefault("DESKCRAB_CHESS_MOVER_EFFORT", "low")

import chess  # noqa: E402

import chess_cli  # noqa: E402
import chess_effort  # noqa: E402
import chess_mover  # noqa: E402
import chess_reflex  # noqa: E402

SP_DIR = chess_mover._chess_dir() / "selfplay"
LOG_FILE = SP_DIR / ("night-" + time.strftime("%Y%m%d") + ".log")

PLY_CAP = 240           # backstop: agree a draw rather than shuffle forever
HOT_MINUTES = 15        # leave the accounts alone while a person's game moves
MOVE_TIMEOUT = 240      # one position may not eat more than this per chunk


def nightly_games():
    try:
        return int(os.environ.get("DESKCRAB_CHESS_SELFPLAY_NIGHTLY_GAMES",
                                  "4"))
    except ValueError:
        return 4


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    try:
        SP_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def load_game(gid):
    with open(chess_cli.GAMES_DIR / f"{gid}.json", encoding="utf-8") as fh:
        return json.load(fh)


def browser_game_hot():
    """True while any live browser game file changed in the last window —
    a person may be at the board, and the resident mover owns the accounts."""
    cutoff = time.time() - HOT_MINUTES * 60
    for p in chess_cli.GAMES_DIR.glob("browser-*.json"):
        try:
            if p.stat().st_mtime <= cutoff:
                continue
            g = json.load(open(p, encoding="utf-8"))
            board = chess_cli.build_board(g)
            if chess_cli.compute_state(g, board)[0] == "active":
                return True
        except Exception:
            return True  # unreadable fresh file: assume hot, stay away
    return False


def selfplay_games():
    out = []
    for p in sorted(chess_cli.GAMES_DIR.glob("selfplay-*.json")):
        try:
            out.append(json.load(open(p, encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
    return out


def created_today(g):
    """Was this game created on today's calendar date (local)?"""
    try:
        stamp = datetime.fromisoformat(g.get("created", ""))
    except ValueError:
        return False
    return stamp.astimezone().date() == datetime.now().astimezone().date()


def new_game(games):
    n = 1
    taken = {g["id"] for g in games}
    while f"selfplay-{n:03d}" in taken:
        n += 1
    side = "white" if n % 2 == 1 else "black"  # alternate the my_side label
    g = {"id": f"selfplay-{n:03d}", "opponent": "selfplay", "my_side": side,
         "moves": [], "resigned_by": None, "draw_agreed": False,
         "engine_level": None, "created": chess_cli.now()}
    chess_cli.save_game(g)
    log(f"{g['id']}: new self-play game (my_side {side})")
    return g


def make_play(side):
    """The mover's posting callback: validate against the store as it stands
    NOW, exactly as chessweb._post_model_move does, then write through
    save_game so reflex ingestion sees every save."""
    def play(job, move):
        try:
            g = load_game(job["gid"])
        except (OSError, json.JSONDecodeError):
            return False
        board = chess_cli.build_board(g)
        if (len(g["moves"]) != job["ply"]
                or board.fen().split()[:4] != job["fen"].split()[:4]
                or chess_cli.compute_state(g, board)[0] != "active"
                or move not in board.legal_moves):
            log(f"{job['gid']} ply {job['ply']}: {side} answer arrived stale "
                "— discarded")
            return False
        san = board.san(move)
        board.push(move)
        g["moves"].append(move.uci())
        chess_cli.save_game(g)
        took = time.time() - job["t0"]
        chess_cli.metric("move-played", f"{job['gid']} ply {job['ply']} "
                         f"{san} model")
        chess_cli.metric("move-latency", f"{job['gid']} ply {job['ply']} "
                         f"{took:.1f}s model")
        log(f"{job['gid']} ply {job['ply']}: {side} played {san} "
            f"(model, effort {job['effort'] or 'default'}, {took:.1f}s)")
        return True
    return play


def move_effort(g, board):
    """The effort pre-check, both levels cheap by the env defaults above;
    '' (mover default, also cheap here) on any failure."""
    ply = len(board.move_stack)
    try:
        level, reasons = chess_effort.classify(
            board, novel=chess_effort.novelty(board.fen()))
        why = ",".join(reasons) if reasons else "quiet"
        chess_cli.metric("effort", f"{g['id']} ply {ply} {level} {why}")
        return level
    except Exception as e:
        log(f"effort pre-check failed, mover default: {e!r}")
        chess_cli.metric("effort", f"{g['id']} ply {ply} default error")
        return ""


def similar_note(g, board):
    ply = len(board.move_stack)
    try:
        import chess_similar
        note = chess_similar.reason_note(board)
        chess_cli.metric("similar-context", f"{g['id']} ply {ply} "
                         + ("attached" if note else "empty"))
        return note
    except Exception as e:
        log(f"similar note failed, prompt goes without: {e!r}")
        return ""


def try_reflex(g, board, t0):
    ply = len(board.move_stack)
    try:
        best = chess_reflex.best_move(board.fen(), board)
    except Exception as e:
        log(f"reflex lookup failed, thinking instead: {e}")
        chess_cli.metric("reflex-miss", f"{g['id']} ply {ply} error")
        return False
    if best is None:
        chess_cli.metric("reflex-miss", f"{g['id']} ply {ply}")
        return False
    chess_cli.metric("reflex-hit", f"{g['id']} ply {ply} {best['move']}"
                     f" n={best['n']} score={best['score']:.2f}")
    move = chess.Move.from_uci(best["move"])
    san = board.san(move)
    side = "white" if board.turn == chess.WHITE else "black"
    board.push(move)
    g["moves"].append(move.uci())
    chess_cli.save_game(g)
    chess_cli.metric("move-played", f"{g['id']} ply {ply} {san} reflex")
    chess_cli.metric("move-latency",
                     f"{g['id']} ply {ply} {time.time() - t0:.1f}s reflex")
    why = (f"{best['n']} game(s), score {best['score']:.2f}" if best["n"]
           else f"book, {best['book']} line(s)")
    log(f"{g['id']} ply {ply}: {side} played {san} (reflex — {why})")
    return True


def play_one_move(g, movers):
    """One ply, whoever's turn it is. Returns 'moved', 'over', 'hot',
    'budget-spent', 'failed', or 'stalled'."""
    board = chess_cli.build_board(g)
    state, desc, result = chess_cli.compute_state(g, board)
    if state != "active":
        return "over"
    ply = len(g["moves"])
    # Rules-legal draw claims, and the hard cap, keep the grind moving.
    if ply >= PLY_CAP:
        g["draw_agreed"] = True
        chess_cli.save_game(g)
        log(f"{g['id']}: draw agreed at the {PLY_CAP}-ply cap")
        return "over"
    if board.can_claim_threefold_repetition():
        g["draw_agreed"] = True
        chess_cli.save_game(g)
        log(f"{g['id']}: draw claimed (threefold repetition) at ply {ply}")
        return "over"
    if board.can_claim_fifty_moves():
        g["draw_agreed"] = True
        chess_cli.save_game(g)
        log(f"{g['id']}: draw claimed (fifty-move rule) at ply {ply}")
        return "over"
    t0 = time.time()
    if try_reflex(g, board, t0):
        return "moved"
    # The nightly move budget, checked HERE before anything is submitted
    # (specs/chess-selfplay.md rule 9): the mover's own refusal (rule 5) is
    # the backstop, not the plan.
    if chess_mover.selfplay_budget_spent():
        return "budget-spent"
    if browser_game_hot():
        return "hot"  # a model call would contend with the live mover
    side = "white" if board.turn == chess.WHITE else "black"
    mover = movers[side]
    key = f"{g['id']}:{chess_reflex.fen_key(board.fen())}"
    job = {"key": key, "gid": g["id"], "ply": ply, "fen": board.fen(),
           "side": side, "opponent": g["opponent"],
           "history": chess_cli.history(g["moves"]),
           "note": similar_note(g, board),
           "effort": move_effort(g, board), "t0": t0}
    deadline = time.time() + MOVE_TIMEOUT
    while time.time() < deadline:
        if mover.claim(key):
            mover.submit(job)
            mover.wait_idle(timeout=min(150, deadline - time.time()))
        g2 = load_game(g["id"])
        if len(g2["moves"]) > ply:
            g.clear()
            g.update(g2)
            return "moved"
        n, stalled, why = mover.failure_state(key)
        if why and "budget spent" in why:
            return "budget-spent"
        if stalled:
            log(f"{g['id']} ply {ply}: {side} STALLED after {n} failed "
                f"rounds — last cause: {why or 'unknown'}")
            return "stalled"
        time.sleep(3)
    n, _, why = mover.failure_state(key)
    log(f"{g['id']} ply {ply}: {side} made no move inside {MOVE_TIMEOUT}s "
        f"({n} failed round(s), last cause: {why or 'unknown'})")
    return "failed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=float, default=360.0,
                    help="seconds this chunk may spend before exiting")
    ap.add_argument("--games", type=int, default=nightly_games(),
                    help="new self-play games allowed per calendar day")
    ap.add_argument("--deadline", default="07:00",
                    help="local HH:MM after which no new work starts")
    args = ap.parse_args()

    started = time.time()
    hh, mm = args.deadline.split(":")
    now_t = time.localtime()
    deadline_ts = time.mktime(now_t[:3] + (int(hh), int(mm), 0) + now_t[6:])
    if deadline_ts < started - 3600:  # started after the deadline hour: past
        deadline_ts += 86400

    movers = {"white": chess_mover.Mover(make_play("white"), log=log,
                                         metric=chess_cli.metric, alert=log),
              "black": chess_mover.Mover(make_play("black"), log=log,
                                         metric=chess_cli.metric, alert=log)}

    moved = 0
    status = "budget"
    consecutive_failures = 0
    while True:
        if time.time() - started >= args.budget:
            status = "budget"
            break
        if time.time() >= deadline_ts:
            status = "deadline"
            break
        # Rule 9: when the night's move budget is spent, stop booking more —
        # cleanly, before any position is offered to a mover.
        if chess_mover.selfplay_budget_spent():
            log("nightly move budget spent "
                f"({chess_mover.selfplay_calls_today()}"
                f"/{chess_mover.selfplay_nightly_moves()}) — stopping")
            status = "budget-spent"
            break
        games = selfplay_games()
        active = [g for g in games if chess_cli.compute_state(
            g, chess_cli.build_board(g))[0] == "active"]
        g = active[0] if active else None
        if g is None:
            if sum(1 for x in games if created_today(x)) >= args.games:
                log(f"games cap reached ({args.games} created today) "
                    "— stopping")
                status = "games-cap"
                break
            if browser_game_hot():
                log("live browser game is hot — waiting, no new game")
                time.sleep(60)
                continue
            g = new_game(games)
        outcome = play_one_move(g, movers)
        if outcome == "moved":
            moved += 1
            consecutive_failures = 0
        elif outcome == "over":
            board = chess_cli.build_board(g)
            state, desc, result = chess_cli.compute_state(g, board)
            log(f"{g['id']}: finished — {desc} [{result}] "
                f"after {len(g['moves'])} plies")
        elif outcome == "budget-spent":
            log("nightly move budget spent "
                f"({chess_mover.selfplay_calls_today()}"
                f"/{chess_mover.selfplay_nightly_moves()}) — stopping")
            status = "budget-spent"
            break
        elif outcome == "hot":
            log("live browser game is hot — pausing the grind")
            time.sleep(60)
        elif outcome in ("failed", "stalled"):
            consecutive_failures += 1
            if outcome == "stalled" or consecutive_failures >= 2:
                status = "failing"
                break
            time.sleep(10)

    # Kill anything still in flight: an orphaned model call outliving the
    # chunk would burn a second answer nobody can post.
    for m in movers.values():
        m.reset()

    games = selfplay_games()
    done = sum(1 for g in games if chess_cli.compute_state(
        g, chess_cli.build_board(g))[0] != "active")
    print("STATUS " + json.dumps({
        "status": status, "moves_this_chunk": moved,
        "selfplay_finished": done, "selfplay_total": len(games)}), flush=True)


if __name__ == "__main__":
    main()
