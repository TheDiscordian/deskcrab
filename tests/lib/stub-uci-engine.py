#!/usr/bin/env python3
"""A minimal UCI engine: legal random moves, and a Skill Level to set.

Here so that crab-chess's engine path is exercised on every test run rather
than only on a machine that happens to have stockfish installed. It answers
uci/isready/setoption/position/go/quit and nothing else, and it plays badly
on purpose — the point is the protocol, not the chess.

Run it with the chess venv's python; tests/test_chess.sh writes the shim.
"""
import random
import sys

import chess

board = chess.Board()

for line in sys.stdin:
    cmd = line.strip()
    if cmd == "uci":
        print("id name randomfish")
        print("id author betty")
        print("option name Skill Level type spin default 20 min 0 max 20")
        print("uciok")
    elif cmd == "isready":
        print("readyok")
    elif cmd.startswith("setoption"):
        print(f"info string {cmd}", file=sys.stderr)
        continue
    elif cmd == "ucinewgame":
        board = chess.Board()
        continue
    elif cmd.startswith("position"):
        parts = cmd.split()
        if "fen" in parts:
            i = parts.index("fen")
            j = parts.index("moves") if "moves" in parts else len(parts)
            board = chess.Board(" ".join(parts[i + 1:j]))
        else:
            board = chess.Board()
        if "moves" in parts:
            for uci in parts[parts.index("moves") + 1:]:
                board.push_uci(uci)
        continue
    elif cmd.startswith("go"):
        move = random.choice(list(board.legal_moves))
        print(f"bestmove {move.uci()}")
    elif cmd == "quit":
        break
    else:
        continue
    sys.stdout.flush()
