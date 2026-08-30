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
                         [--day]
"""

import argparse
import json
import os
import random
import re
import statistics
import sys
import time
from datetime import datetime, timedelta
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
LOG_FILE = SP_DIR / ("night-" + chess_mover.night_key() + ".log")

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


def night_of(dt):
    """The night a moment belongs to (specs/chess-selfplay.md rule 4): the
    local calendar date twelve hours earlier, so noon D to noon D+1 is all
    one night, D's."""
    return (dt.astimezone() - timedelta(hours=12)).date()


def created_tonight(g, now=None):
    """Was this game created inside the current night's window? Rule 6 counts
    games per night, same window as the move budget, so a chain crossing
    midnight cannot open a second batch of games at 00:00."""
    try:
        stamp = datetime.fromisoformat(g.get("created", ""))
    except ValueError:
        return False
    if now is None:
        now = datetime.now().astimezone()
    return night_of(stamp) == night_of(now)


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
        took = time.time() - job["t0"]
        # The same clock charge as every other recording path (rule 17); an
        # untimed game — every ordinary self-play game — is untouched by it.
        chess_cli.clock_move(g)
        # A clock-budget fallback (chessweb.md rule 16g) is recorded under
        # its own source: a move the model FAILED to answer, and the
        # benchmark counts it against the configuration that needed it.
        source = "fallback" if job.get("fallback") else "model"
        if "bench" in g:
            g["bench"]["rows"].append([job["ply"], side, source,
                                       job.get("effort") or "default",
                                       round(took, 2)])
        chess_cli.save_game(g)
        chess_cli.metric("move-played", f"{job['gid']} ply {job['ply']} "
                         f"{san} {source}")
        chess_cli.metric("move-latency", f"{job['gid']} ply {job['ply']} "
                         f"{took:.1f}s {source}")
        log(f"{job['gid']} ply {job['ply']}: {side} played {san} "
            f"({source}, effort {job['effort'] or 'default'}, {took:.1f}s)")
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
    chess_cli.clock_move(g)  # timed benchmark games only; untimed untouched
    if "bench" in g:
        g["bench"]["rows"].append([ply, side, "reflex", "",
                                   round(time.time() - t0, 2)])
    chess_cli.save_game(g)
    chess_cli.metric("move-played", f"{g['id']} ply {ply} {san} reflex")
    chess_cli.metric("move-latency",
                     f"{g['id']} ply {ply} {time.time() - t0:.1f}s reflex")
    why = (f"{best['n']} game(s), score {best['score']:.2f}" if best["n"]
           else f"book, {best['book']} line(s)")
    log(f"{g['id']} ply {ply}: {side} played {san} (reflex — {why})")
    return True


def play_one_move(g, movers, bench=None):
    """One ply, whoever's turn it is. Returns 'moved', 'over', 'hot',
    'budget-spent', 'failed', or 'stalled'. `bench` is (plan, spec) in
    benchmark mode: openings come from the book at random for the first
    plies (rule 18), and the side to move thinks with its OWN configuration
    — its model on the job, its quiet/sharp pair through the classifier
    (rule 15)."""
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
    if bench and bench_book_move(g, board, t0):
        return "moved"
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
    # Position memory rides the mover's own prompt build (chess-reflex.md
    # rule 14); no note is computed here.
    job = {"key": key, "gid": g["id"], "ply": ply, "fen": board.fen(),
           "side": side, "opponent": g["opponent"],
           "history": chess_cli.history(g["moves"]), "t0": t0,
           # The live clock rides the job for a TIMED game (benchmark games
           # are the timed self-play), so rule 16g's clock budget binds the
           # grind's calls exactly as it binds a live game's; None for the
           # ordinary untimed grind, which is untouched by it.
           "clock": chess_cli.clock_remaining(g, board)}
    if bench:
        plan, spec = bench
        cfg = plan["configs"][spec[side]]
        job["model"] = cfg["model"]
        job["effort"] = bench_effort(g, board, cfg)
    else:
        job["effort"] = move_effort(g, board)
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
        # A clock may have run out while the think was in flight: a fallen
        # flag is a finished game, never a failed move (rule 17).
        if chess_cli.compute_state(g2, chess_cli.build_board(g2))[0] \
                != "active":
            g.clear()
            g.update(g2)
            return "over"
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


# --- the benchmark (specs/chess-selfplay.md rules 14-19) --------------------
# Adopted 2026-08-27: batches of self-play across the standard time controls,
# a model-and-effort configuration per side, colours rotated, so the pairing a
# real game should think at per control is chosen from measured games. Every
# guard above rides along unchanged; the plan file plus the game files are the
# whole resumable state.

def bench_book_plies():
    try:
        return int(os.environ.get("DESKCRAB_CHESS_BENCH_BOOK_PLIES", "6"))
    except ValueError:
        return 6


def bench_book_move(g, board, t0):
    """Rule 18: for the first plies of a benchmark game, a uniformly random
    legal book move — so a batch samples openings instead of replaying the
    store's one favourite line into itself. False (fall through to the
    normal path) past the ply window, on an empty book, or on any failure."""
    ply = len(board.move_stack)
    if ply >= bench_book_plies():
        return False
    try:
        legal = []
        for cand in chess_reflex.lookup(board.fen()):
            if not cand["book"]:
                continue
            try:
                m = chess.Move.from_uci(cand["move"])
            except (chess.InvalidMoveError, ValueError):
                continue
            if m in board.legal_moves:
                legal.append(m)
    except Exception as e:
        log(f"bench book lookup failed, normal path instead: {e!r}")
        return False
    if not legal:
        return False
    move = random.choice(legal)
    san = board.san(move)
    side = "white" if board.turn == chess.WHITE else "black"
    board.push(move)
    g["moves"].append(move.uci())
    chess_cli.clock_move(g)
    g["bench"]["rows"].append([ply, side, "book", "",
                               round(time.time() - t0, 2)])
    chess_cli.save_game(g)
    chess_cli.metric("move-played", f"{g['id']} ply {ply} {san} book")
    log(f"{g['id']} ply {ply}: {side} played {san} (book, random opening)")
    return True


def bench_effort(g, board, cfg):
    """Rule 15: the classifier decides quiet-or-sharp exactly as a real game
    would, and the SIDE'S OWN pair prices the answer. The config's quiet
    level on any failure — a benchmark move must never fall back to another
    side's price."""
    ply = len(board.move_stack)
    try:
        level, reasons = chess_effort.classify(
            board, novel=chess_effort.novelty(board.fen()),
            pair=(cfg["quiet"], cfg["sharp"]))
        why = ",".join(reasons) if reasons else "quiet"
        chess_cli.metric("effort", f"{g['id']} ply {ply} {level} {why}")
        return level
    except Exception as e:
        log(f"bench effort pre-check failed, quiet level: {e!r}")
        chess_cli.metric("effort", f"{g['id']} ply {ply} {cfg['quiet']} error")
        return cfg["quiet"]


def bench_ledger_path(plan):
    return SP_DIR / ("bench-%s.jsonl" % plan["run"])


def bench_ledger_append(plan, entry):
    SP_DIR.mkdir(parents=True, exist_ok=True)
    with open(bench_ledger_path(plan), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


def bench_ledger_lines(plan):
    out = []
    try:
        with open(bench_ledger_path(plan), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        pass
    return out


def bench_recorded(plan):
    """Game ids already on the ledger — the exactly-once guard (rule 19)."""
    return {e["game"] for e in bench_ledger_lines(plan) if "game" in e}


def bench_new_game(spec, plan):
    tc, ck = chess_cli.make_time_control(spec["control"])
    g = {"id": spec["id"], "opponent": "selfplay", "my_side": "white",
         "moves": [], "resigned_by": None, "draw_agreed": False,
         "engine_level": None, "created": chess_cli.now(),
         "bench": {"control": spec["control"],
                   "white": spec["white"], "black": spec["black"],
                   "rows": []}}
    if tc:
        g["time_control"] = tc
        g["clock"] = ck
    chess_cli.save_game(g)
    log(f"{g['id']}: new benchmark game — {spec['control']}, "
        f"white {spec['white']}, black {spec['black']}")
    return g


def bench_attempts(gid):
    """Per-side counted model ATTEMPTS for a game, mined from rule 4's
    counter files (one line per attempt, detail `<gid> ply <n> <label>`) —
    every night's file, because a resumed cell spans nights. Attempts in
    excess of landed model moves are the retries and failed rounds the
    ledger owes the record (rule 19). Best-effort: an unreadable counter
    is zeros, never a lost recording."""
    counts = {"white": 0, "black": 0}
    try:
        for p in sorted(SP_DIR.glob("model-calls-*.log")):
            with open(p, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    d = line.rstrip("\n").split("\t")[-1].split()
                    if len(d) >= 3 and d[0] == gid and d[1] == "ply":
                        try:
                            ply = int(d[2])
                        except ValueError:
                            continue
                        counts["white" if ply % 2 == 0 else "black"] += 1
    except OSError:
        pass
    return counts


def bench_record_game(plan, spec, g):
    """One ledger line per finished game, carrying the whole verdict a
    selection needs (rule 19): result, termination, flags, final remaining
    clock, per-side move counts by source (fallback rescues included),
    latency summaries, and counted attempts. A live-judged flag is recorded
    onto the game first, so the file reads finished forever without a wall
    clock in hand."""
    board = chess_cli.build_board(g)
    flagged = chess_cli.flag_fallen(g, board)
    if flagged and not g.get("flag_fell"):
        g["flag_fell"] = flagged
        chess_cli.save_game(g)
    state, desc, result = chess_cli.compute_state(g, board)
    rows = (g.get("bench") or {}).get("rows", [])
    attempts = bench_attempts(g["id"])

    def side_summary(side):
        mine = [r for r in rows if r[1] == side]
        model = [r[4] for r in mine if r[2] == "model"]
        return {"model_moves": len(model),
                "reflex_moves": sum(1 for r in mine if r[2] == "reflex"),
                "book_moves": sum(1 for r in mine if r[2] == "book"),
                "fallback_moves": sum(1 for r in mine
                                      if r[2] == "fallback"),
                "attempts": attempts.get(side, 0),
                "model_secs_median": (round(statistics.median(model), 2)
                                      if model else None),
                "model_secs_max": max(model) if model else None}

    ck = g.get("clock") or {}
    bench_ledger_append(plan, {
        "game": g["id"], "control": spec["control"],
        "white": spec["white"], "black": spec["black"],
        "result": result, "state": state, "desc": desc,
        "plies": len(g["moves"]), "flagged": g.get("flag_fell"),
        "clock_remaining": ({"white_ms": ck.get("white_ms"),
                             "black_ms": ck.get("black_ms")}
                            if ck else None),
        "sides": {"white": side_summary("white"),
                  "black": side_summary("black")},
        "finished": chess_cli.now()})
    log(f"{g['id']}: recorded — {desc} [{result}] "
        f"after {len(g['moves'])} plies")


def run_bench(args, plan, started, deadline_ts):
    """The benchmark chunk: the plan's games in order, one at a time,
    skipping what is finished and recorded — so the plan file plus the game
    files are the resumable state, and a re-run of a finished plan replays
    nothing. Returns (status, moved)."""
    movers = {"white": chess_mover.Mover(make_play("white"), log=log,
                                         metric=chess_cli.metric, alert=log),
              "black": chess_mover.Mover(make_play("black"), log=log,
                                         metric=chess_cli.metric, alert=log)}
    recorded = bench_recorded(plan)
    moved = 0
    status = "bench-done"
    consecutive_failures = 0
    try:
        for spec in plan["games"]:
            path = chess_cli.GAMES_DIR / (spec["id"] + ".json")
            g = load_game(spec["id"]) if path.exists() else None
            if g is not None and chess_cli.compute_state(
                    g, chess_cli.build_board(g))[0] != "active":
                if spec["id"] not in recorded:
                    bench_record_game(plan, spec, g)
                    recorded.add(spec["id"])
                continue
            while True:
                if time.time() - started >= args.budget:
                    return "budget", moved
                if time.time() >= deadline_ts:
                    return "deadline", moved
                if chess_mover.selfplay_budget_spent():
                    log("nightly move budget spent "
                        f"({chess_mover.selfplay_calls_tonight()}"
                        f"/{chess_mover.selfplay_nightly_moves()}) "
                        "— stopping")
                    return "budget-spent", moved
                if g is None:
                    games = selfplay_games()
                    if sum(1 for x in games
                           if created_tonight(x)) >= args.games:
                        log(f"games cap reached ({args.games} tonight) "
                            "— stopping")
                        return "games-cap", moved
                    if browser_game_hot():
                        log("live browser game is hot — waiting")
                        time.sleep(60)
                        continue
                    g = bench_new_game(spec, plan)
                outcome = play_one_move(g, movers, bench=(plan, spec))
                if outcome == "moved":
                    moved += 1
                    consecutive_failures = 0
                elif outcome == "over":
                    bench_record_game(plan, spec, g)
                    recorded.add(spec["id"])
                    break
                elif outcome == "budget-spent":
                    log("nightly move budget spent "
                        f"({chess_mover.selfplay_calls_tonight()}"
                        f"/{chess_mover.selfplay_nightly_moves()}) "
                        "— stopping")
                    return "budget-spent", moved
                elif outcome == "hot":
                    log("live browser game is hot — pausing the grind")
                    time.sleep(60)
                elif outcome in ("failed", "stalled"):
                    consecutive_failures += 1
                    if outcome == "stalled" or consecutive_failures >= 2:
                        return "failing", moved
                    time.sleep(10)
    finally:
        for m in movers.values():
            m.reset()
    return status, moved


def bench_probe(args, plan):
    """Rule 19's probe: bare per-call latency for the plan's probe
    configurations over its fixed positions — each call a self-play mover
    call, budget-counted and allowlist-bound, so a model too dear to grind
    still gets its latency measured for a few counted calls."""
    probe = plan.get("probe") or {}
    configs = probe.get("configs") or []
    fens = probe.get("positions") or [chess.STARTING_FEN]
    rounds = int(probe.get("rounds", 1))
    done = 0
    landed = []

    def play(job, move):
        landed.append(job["key"])
        return True

    mover = chess_mover.Mover(play, log=log, metric=chess_cli.metric,
                              alert=log)
    try:
        for r in range(rounds):
            for model, effort in configs:
                for i, fen in enumerate(fens):
                    if chess_mover.selfplay_budget_spent():
                        log("nightly move budget spent — probe stops")
                        return done
                    if browser_game_hot():
                        log("live browser game is hot — probe stops")
                        return done
                    board = chess.Board(fen)
                    key = f"probe-{model}-{effort}-{i}-{r}"
                    t0 = time.time()
                    job = {"key": key, "gid": "selfplay-bench-probe",
                           "ply": 0, "fen": board.fen(),
                           "side": ("white" if board.turn else "black"),
                           "opponent": "selfplay", "history": "",
                           "model": model, "effort": effort, "t0": t0}
                    mover.submit(job)
                    mover.wait_idle(timeout=240)
                    secs = round(time.time() - t0, 2)
                    ok = key in landed
                    n, _, why = mover.failure_state(key)
                    bench_ledger_append(plan, {
                        "probe": model, "effort": effort, "pos": i,
                        "round": r, "secs": secs, "ok": ok,
                        "why": (why or None) if not ok else None})
                    log(f"probe {model}/{effort} pos {i}: "
                        f"{secs}s {'ok' if ok else 'FAILED: ' + (why or '?')}")
                    done += 1
    finally:
        mover.reset()
    return done


# Three probe positions: the opening (quiet), a middlegame with tension, a
# sharp tactical stand — so a probe prices the prompt sizes a real game
# actually produces.
PROBE_FENS = [
    chess.STARTING_FEN,
    "r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P1B2/2P1PN2/PP1N1PPP/R2QKB1R w KQ - 0 8",
    "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 4 5",
]


def bench_default_plan(run):
    """The shipped schedule: five affordable configurations bracketing the
    model-and-effort space, each control comparing the neighbours its clock
    makes interesting, every matchup twice with colours swapped (rule 16)."""
    configs = {
        "haiku-ll": {"model": "haiku", "quiet": "low", "sharp": "low"},
        "haiku-lm": {"model": "haiku", "quiet": "low", "sharp": "medium"},
        "sonnet-ll": {"model": "sonnet", "quiet": "low", "sharp": "low"},
        "sonnet-lm": {"model": "sonnet", "quiet": "low", "sharp": "medium"},
        "sonnet-mh": {"model": "sonnet", "quiet": "medium", "sharp": "high"},
    }
    matchups = {
        "1+0": [("haiku-ll", "sonnet-ll"), ("haiku-ll", "haiku-lm")],
        "2+1": [("haiku-ll", "sonnet-ll"), ("sonnet-ll", "sonnet-lm")],
        "3+2": [("sonnet-ll", "sonnet-lm"), ("sonnet-ll", "haiku-lm")],
        "5+0": [("sonnet-ll", "sonnet-lm"), ("sonnet-lm", "haiku-lm")],
        "10+0": [("sonnet-lm", "sonnet-mh"), ("sonnet-ll", "sonnet-lm")],
        "15+10": [("sonnet-lm", "sonnet-mh"), ("sonnet-ll", "sonnet-mh")],
    }
    games = []
    n = 0
    for control, pairs in matchups.items():
        for a, b in pairs:
            for white, black in ((a, b), (b, a)):
                n += 1
                games.append({"id": "selfplay-bench%s-%03d" % (run, n),
                              "control": control,
                              "white": white, "black": black})
    return {"run": run,
            "probe": {"configs": [["haiku", "low"], ["haiku", "medium"],
                                  ["sonnet", "low"], ["sonnet", "medium"],
                                  ["sonnet", "high"]],
                      "positions": PROBE_FENS, "rounds": 1},
            "configs": configs, "games": games}


# The corrective matrix (specs/chess-selfplay.md rule 20, adopted 2026-08-28
# on the user's rejection of the probe-based verdict): every supported live
# mover model at every effort the CLI accepts, each as a UNIFORM pair so a
# cell measures exactly one model-and-effort pair playing whole games,
# against one common reference, colours rotated, every timed control,
# fastest first. Probes are never selection evidence; these games are.
# The matrix crosses model FAMILY as well as effort (rule 20, amended
# 2026-08-29 on the user's acceptance criterion): the codex-family
# candidates ride the same matrix at every effort the codex engine accepts
# — the shared five plus its own `ultra` — behind rule 15's explicit
# allowlisting and codex-only attempt list.
MATRIX_MODELS = ["sonnet", "haiku", "opus", "fable"]
MATRIX_EFFORTS = ["low", "medium", "high", "xhigh", "max"]
MATRIX_CODEX_MODELS = ["sol"]
MATRIX_CODEX_EFFORTS = MATRIX_EFFORTS + ["ultra"]
MATRIX_REFERENCE = "sonnet-low"
MATRIX_CONTROLS = ["1+0", "2+1", "3+2", "5+0", "10+0", "15+10"]


def bench_matrix_configs():
    """Every configuration rule 20 owes, uniform pairs all."""
    configs = {}
    for model in MATRIX_MODELS:
        for effort in MATRIX_EFFORTS:
            configs["%s-%s" % (model, effort)] = {
                "model": model, "quiet": effort, "sharp": effort}
    for model in MATRIX_CODEX_MODELS:
        for effort in MATRIX_CODEX_EFFORTS:
            configs["%s-%s" % (model, effort)] = {
                "model": model, "quiet": effort, "sharp": effort}
    return configs


def bench_matrix_cells(reps=2):
    """Every (control, white, black) game rule 20 owes, in play order:
    controls fastest first; within a control the Claude families at the
    CLI's five efforts, then the codex-family candidates at their own
    effort list; every cell reps colour-rotated games against the
    reference, whose own cell is its mirror."""
    cells = []

    def cell(control, model, effort):
        cfg = "%s-%s" % (model, effort)
        for r in range(reps):
            white, black = ((cfg, MATRIX_REFERENCE) if r % 2 == 0
                            else (MATRIX_REFERENCE, cfg))
            cells.append((control, white, black))

    for control in MATRIX_CONTROLS:
        for effort in MATRIX_EFFORTS:
            for model in MATRIX_MODELS:
                cell(control, model, effort)
        for model in MATRIX_CODEX_MODELS:
            for effort in MATRIX_CODEX_EFFORTS:
                cell(control, model, effort)
    return cells


def bench_matrix_plan(run, reps=2):
    """The rule-20 plan: reps colour-rotated games per (configuration,
    control) cell against the reference; the reference's own cell is its
    mirror. No probe section — a route is chosen from complete games."""
    games = [{"id": "selfplay-bench%s-%03d" % (run, n + 1),
              "control": control, "white": white, "black": black}
             for n, (control, white, black)
             in enumerate(bench_matrix_cells(reps))]
    return {"run": run, "configs": bench_matrix_configs(), "games": games}


def bench_extend_matrix(plan, reps=2):
    """Rule 20's extend mode: append whatever matrix cells `plan` is
    missing, so a matrix widened after play began extends the SAME
    resumable plan instead of restarting it. Additions land at the END of
    their control's block (play order stays fastest-control first), ids
    continue the plan's numbering, existing games — played or not — are
    untouched, and a second run appends nothing. Returns the appended
    specs."""
    plan.setdefault("configs", {})
    for name, cfg in bench_matrix_configs().items():
        plan["configs"].setdefault(name, cfg)
    have = {}
    for g in plan.get("games", []):
        k = (g["control"], g["white"], g["black"])
        have[k] = have.get(k, 0) + 1
    missing = []
    for k in bench_matrix_cells(reps):
        if have.get(k, 0) > 0:
            have[k] -= 1
        else:
            missing.append(k)
    if not missing:
        return []
    n = 0
    for g in plan.get("games", []):
        m = re.search(r"-(\d+)$", g["id"])
        if m:
            n = max(n, int(m.group(1)))
    added, by_control = [], {}
    for control, white, black in missing:
        n += 1
        spec = {"id": "selfplay-bench%s-%03d" % (plan["run"], n),
                "control": control, "white": white, "black": black}
        added.append(spec)
        by_control.setdefault(control, []).append(spec)
    games, out = list(plan.get("games", [])), []
    for i, g in enumerate(games):
        out.append(g)
        c = g["control"]
        if ((i + 1 == len(games) or games[i + 1]["control"] != c)
                and c in by_control):
            out.extend(by_control.pop(c))
    for control in MATRIX_CONTROLS:  # controls the plan had no games for
        out.extend(by_control.pop(control, []))
    for control in sorted(by_control):  # never reached today; never dropped
        out.extend(by_control.pop(control))
    plan["games"] = out
    return added


def bench_report(plan):
    """Rule 19's report: the measured tables, no recommendation — choosing
    is the reader's job. Markdown to stdout."""
    lines = bench_ledger_lines(plan)
    games = [e for e in lines if "game" in e]
    probes = [e for e in lines if "probe" in e]
    print(f"# Self-play benchmark {plan['run']}")
    print()
    total = len(plan.get("games", []))
    print(f"{len(games)} of {total} scheduled games finished, "
          f"{len(probes)} probe calls.")
    if probes:
        print()
        print("## Probe: bare per-call latency (seconds)")
        print()
        print("| model | effort | calls | min | median | max | failures |")
        print("|---|---|---|---|---|---|---|")
        by = {}
        for p in probes:
            by.setdefault((p["probe"], p["effort"]), []).append(p)
        for (model, effort), ps in sorted(by.items()):
            secs = [p["secs"] for p in ps if p["ok"]]
            fails = sum(1 for p in ps if not p["ok"])
            if secs:
                print(f"| {model} | {effort} | {len(ps)} | {min(secs):.1f} "
                      f"| {statistics.median(secs):.1f} | {max(secs):.1f} "
                      f"| {fails} |")
            else:
                print(f"| {model} | {effort} | {len(ps)} | - | - | - "
                      f"| {fails} |")
    controls = []
    for spec in plan.get("games", []):
        if spec["control"] not in controls:
            controls.append(spec["control"])
    for control in controls:
        cg = [e for e in games if e["control"] == control]
        if not cg:
            continue
        print()
        print(f"## {control} — {len(cg)} game(s)")
        print()
        tally = {}
        for e in cg:
            for side in ("white", "black"):
                cfg = e[side]
                t = tally.setdefault(cfg, {"games": 0, "wins": 0, "draws": 0,
                                           "losses": 0, "flags": 0,
                                           "fallbacks": 0, "attempts": 0,
                                           "model_moves": 0, "secs": []})
                t["games"] += 1
                won = {"1-0": "white", "0-1": "black"}.get(e["result"])
                if won is None:
                    t["draws"] += 1
                elif won == side:
                    t["wins"] += 1
                else:
                    t["losses"] += 1
                if e.get("flagged") == side:
                    t["flags"] += 1
                s = e.get("sides", {}).get(side, {})
                t["model_moves"] += s.get("model_moves") or 0
                t["fallbacks"] += s.get("fallback_moves") or 0
                t["attempts"] += s.get("attempts") or 0
                if s.get("model_secs_median") is not None:
                    t["secs"].append(s["model_secs_median"])
        print("| config | games | W-D-L | points | flag losses | fallbacks "
              "| model moves | attempts | median model secs |")
        print("|---|---|---|---|---|---|---|---|---|")
        for cfg, t in sorted(tally.items(),
                             key=lambda kv: -(kv[1]["wins"]
                                              + 0.5 * kv[1]["draws"])):
            pts = t["wins"] + 0.5 * t["draws"]
            med = (f"{statistics.median(t['secs']):.1f}"
                   if t["secs"] else "-")
            print(f"| {cfg} | {t['games']} "
                  f"| {t['wins']}-{t['draws']}-{t['losses']} "
                  f"| {pts:g} | {t['flags']} | {t['fallbacks']} "
                  f"| {t['model_moves']} | {t['attempts']} | {med} |")
        print()
        for e in cg:
            flag = f", {e['flagged']} flagged" if e.get("flagged") else ""
            print(f"- {e['game']}: {e['white']} (white) vs {e['black']} "
                  f"(black) — {e['result']} ({e['desc']}), "
                  f"{e['plies']} plies{flag}")


def resolve_deadline(started, deadline, day):
    """The chunk's morning wall as an epoch, or None for a daytime refusal.

    A start up to an hour past today's `deadline` HH:MM is a late night
    chain still winding down: it keeps today's wall (already passed, so the
    loop stops at once). Further past it, the wall used to roll to tomorrow
    unconditionally — which read a 14:00 manual invocation as an evening
    start aimed at tomorrow and let it grind until 07:00 the next day. Now
    the roll only stands when tomorrow's wall is within 12 h (a real evening
    start); otherwise the start is daytime, and without the explicit --day
    flag the driver refuses rather than run all day (specs/chess-selfplay.md
    rule 8). The night path — evening and small-hours starts — is unchanged.
    """
    hh, mm = deadline.split(":")
    now_t = time.localtime(started)
    deadline_ts = time.mktime(now_t[:3] + (int(hh), int(mm), 0) + now_t[6:])
    if deadline_ts < started - 3600:  # started after the deadline hour: past
        deadline_ts += 86400
        if not day and deadline_ts - started > 12 * 3600:
            return None  # a daytime start, and nobody said --day
    return deadline_ts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=float, default=360.0,
                    help="seconds this chunk may spend before exiting")
    ap.add_argument("--games", type=int, default=nightly_games(),
                    help="new self-play games allowed per night")
    ap.add_argument("--deadline", default="07:00",
                    help="local HH:MM after which no new work starts")
    ap.add_argument("--day", action="store_true",
                    help="a deliberate daytime chunk: run even when the "
                         "start is nowhere near the night's wall")
    ap.add_argument("--bench", metavar="PLAN",
                    help="play the benchmark plan (JSON) for this chunk")
    ap.add_argument("--bench-init", action="store_true",
                    help="write the default benchmark plan and exit")
    ap.add_argument("--bench-init-matrix", action="store_true",
                    help="write the full model-and-effort matrix plan "
                         "(specs/chess-selfplay.md rule 20) and exit")
    ap.add_argument("--bench-extend-matrix", metavar="PLAN",
                    help="append the matrix cells PLAN is missing "
                         "(rule 20) and exit — a widened matrix extends "
                         "the same resumable plan")
    ap.add_argument("--reps", type=int, default=2,
                    help="colour-rotated games per matrix cell")
    ap.add_argument("--bench-probe", metavar="PLAN",
                    help="run the plan's latency probes and exit")
    ap.add_argument("--bench-report", metavar="PLAN",
                    help="render the plan's results and exit")
    ap.add_argument("--run", default=time.strftime("%Y%m%d"),
                    help="benchmark run name for --bench-init")
    args = ap.parse_args()

    if args.bench_init or args.bench_init_matrix:
        SP_DIR.mkdir(parents=True, exist_ok=True)
        path = SP_DIR / ("bench-%s.json" % args.run)
        if path.exists():
            print(f"refusing: {path} already exists", file=sys.stderr)
            sys.exit(1)
        plan = (bench_matrix_plan(args.run, reps=args.reps)
                if args.bench_init_matrix else bench_default_plan(args.run))
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(plan, fh, indent=1)
            fh.write("\n")
        print(path)
        return
    if args.bench_extend_matrix:
        with open(args.bench_extend_matrix, encoding="utf-8") as fh:
            plan = json.load(fh)
        added = bench_extend_matrix(plan, reps=args.reps)
        tmp = args.bench_extend_matrix + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(plan, fh, indent=1)
            fh.write("\n")
        os.replace(tmp, args.bench_extend_matrix)
        print("added %d game(s); the plan now schedules %d"
              % (len(added), len(plan["games"])))
        return
    if args.bench_report:
        with open(args.bench_report, encoding="utf-8") as fh:
            bench_report(json.load(fh))
        return

    started = time.time()
    deadline_ts = resolve_deadline(started, args.deadline, args.day)
    if deadline_ts is None:
        log(f"started {time.strftime('%H:%M', time.localtime(started))}, "
            f"more than an hour past --deadline {args.deadline} and more "
            "than 12 h before the next wall — a daytime start, not a night "
            "chain. Pass --day for a deliberate daytime chunk.")
        games = selfplay_games()
        done = sum(1 for g in games if chess_cli.compute_state(
            g, chess_cli.build_board(g))[0] != "active")
        print("STATUS " + json.dumps({
            "status": "daytime", "moves_this_chunk": 0,
            "selfplay_finished": done, "selfplay_total": len(games)}),
            flush=True)
        sys.exit(2)

    if args.bench_probe:
        with open(args.bench_probe, encoding="utf-8") as fh:
            plan = json.load(fh)
        done = bench_probe(args, plan)
        print("STATUS " + json.dumps({
            "status": "probe-done", "probe_calls": done}), flush=True)
        return

    if args.bench:
        with open(args.bench, encoding="utf-8") as fh:
            plan = json.load(fh)
        status, moved = run_bench(args, plan, started, deadline_ts)
        recorded = bench_recorded(plan)
        games = selfplay_games()
        done = sum(1 for g in games if chess_cli.compute_state(
            g, chess_cli.build_board(g))[0] != "active")
        print("STATUS " + json.dumps({
            "status": status, "moves_this_chunk": moved,
            "bench_recorded": len(recorded),
            "bench_total": len(plan["games"]),
            "selfplay_finished": done, "selfplay_total": len(games)}),
            flush=True)
        return

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
                f"({chess_mover.selfplay_calls_tonight()}"
                f"/{chess_mover.selfplay_nightly_moves()}) — stopping")
            status = "budget-spent"
            break
        games = selfplay_games()
        active = [g for g in games if chess_cli.compute_state(
            g, chess_cli.build_board(g))[0] == "active"]
        g = active[0] if active else None
        if g is None:
            if sum(1 for x in games if created_tonight(x)) >= args.games:
                log(f"games cap reached ({args.games} created tonight) "
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
                f"({chess_mover.selfplay_calls_tonight()}"
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
