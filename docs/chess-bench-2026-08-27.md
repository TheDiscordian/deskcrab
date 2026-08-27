# Self-play benchmark, 2026-08-27: model and effort pairings by time control

The measured results behind `chess_effort.SPEED_PAIRS` (specs/chessweb.md rule 16b) and the
run the benchmark mechanism (specs/chess-selfplay.md rules 14-19, landed 5aa7754) was built
for. The user's ask, the night of 2026-08-27: batches of self-play across the standard time
controls, different model-and-effort configurations on each side, colours rotated, so the
pairing a real game thinks at per control is chosen from measured games rather than by feel —
the finished games feeding the pattern store as every self-play game does.

## Method

- One 24-game plan (`bench-20260827.json`): the five affordable configurations bracketing the
  model-and-effort space — `haiku-ll` (haiku, low/low), `haiku-lm` (haiku, low/medium),
  `sonnet-ll` (sonnet, low/low), `sonnet-lm` (sonnet, low/medium), `sonnet-mh` (sonnet,
  medium/high) — across 1+0, 2+1, 3+2, 5+0, 10+0 and 15+10, every matchup twice with colours
  swapped. `quiet`/`sharp` means the rule-16b classifier still chose per move; the pair names
  which level each verdict buys.
- Real clocks, charged by `chess_cli.clock_move` on wall time, mover queueing, retries and
  failures included (rule 17): a configuration too slow for its clock SHOULD flag, and that
  flag is a result.
- Openings varied by random legal book moves for the first 6 plies (rule 18), so the batch
  samples openings instead of replaying the store's favourite line into itself.
- Probe mode measured bare per-call latency for haiku/sonnet at their game efforts plus fable
  at low/medium — fable is too dear to grind full games, so it got counted probe calls only.
- The run was chunked (~8-minute foreground chunks, `--budget 480-540`), resumable by design:
  plan file plus game files are the whole state. Operator knobs for this run, per rule 14:
  `DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=1200`, `--games 40`, and `--deadline 09:00` for the
  final chunks (the plan's last two 15+10 games crossed 07:00; the live-game hot guard stayed
  active throughout, and no browser game was live).

## Probe: bare per-call latency (seconds)

| model | effort | calls | min | median | max | failures |
|---|---|---|---|---|---|---|
| fable | low | 6 | 3.5 | 3.7 | 4.0 | 3 |
| fable | medium | 6 | 3.9 | 3.9 | 5.6 | 3 |
| haiku | low | 3 | 19.1 | 29.8 | 86.5 | 0 |
| haiku | medium | 6 | 18.0 | 34.6 | 82.2 | 1 |
| sonnet | high | 3 | 3.0 | 3.1 | 3.3 | 0 |
| sonnet | low | 3 | 3.1 | 3.1 | 3.2 | 0 |
| sonnet | medium | 3 | 3.1 | 3.2 | 3.6 | 0 |

The fable failures were account-credit refusals on the first pass (both fable efforts, all
three positions); the second pass, on a healthy login, produced the six clean calls shown.
Read the probe table beside the in-game one below: probes price a bare call on an idle
account, and for sonnet high they wildly understate what a real game pays.

## In-game model-call latency, by configuration and effort level

From the per-move bench rows of all 24 games (source `model` only; book and reflex moves cost
no call):

| config | effort | calls | median | p90 | max | >15s | >60s |
|---|---|---|---|---|---|---|---|
| haiku-ll | low | 3 | 78.9 | 78.9 | 88.3 | 3 | 2 |
| haiku-lm | low | 3 | 58.5 | 58.5 | 62.7 | 3 | 1 |
| haiku-lm | medium | 7 | 71.8 | 86.8 | 178.7 | 7 | 4 |
| sonnet-ll | low | 278 | 3.1 | 3.7 | 96.3 | 7 | 2 |
| sonnet-lm | low | 20 | 3.2 | 3.4 | 72.9 | 1 | 1 |
| sonnet-lm | medium | 286 | 3.3 | 14.7 | 150.5 | 27 | 2 |
| sonnet-mh | high | 146 | 15.8 | 64.3 | 175.3 | 76 | 17 |
| sonnet-mh | medium | 17 | 3.1 | 3.4 | 4.2 | 0 | 0 |

This table is the whole story. Sonnet low is steady: median 3.1s, p90 3.7s. Sonnet medium
has the same median but a real tail: p90 14.7s, nearly one call in ten over 15s. Sonnet high
in a real game runs a 15.8s MEDIAN and a 64s p90 — the 3s probe number is a bare-call
fiction once mid-game prompts and account pressure are in play. Haiku never answered a game
position in under 18s at any effort.

## Results by control

24 of 24 scheduled games finished. Full per-game lines are in the run ledger
(`~/.local/share/deskcrab/chess/selfplay/bench-20260827.jsonl`, rendered by
`chess_selfplay.py --bench-report`); the tables:

### 1+0 (bullet)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-ll | 2 | 2-0-0 | 2 | 0 | 3.1 |
| haiku-ll | 4 | 1-0-3 | 1 | 3 | 59.0 |
| haiku-lm | 2 | 1-0-1 | 1 | 1 | - |

Every decisive result a flag; haiku's one "win" was the other haiku flagging first.

### 2+1 (bullet)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-ll | 4 | 4-0-0 | 4 | 0 | 2.9 |
| haiku-ll | 2 | 0-0-2 | 0 | 2 | 83.6 |
| sonnet-lm | 2 | 0-0-2 | 0 | 2 | 3.1 |

The clean direct signal: sonnet-ll beat sonnet-lm twice, both by flag, and both were genuine
steady bleed — lm's clock ran to 7.2s and 2.2s over 54-57 plies. A 3.3s median with a 15s
p90 tail against +1s increment loses on time with no help from anyone.

### 3+2 (blitz)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-ll | 4 | 4-0-0 | 4 | 0 | 3.1 |
| sonnet-lm | 2 | 0-0-2 | 0 | 2 | 4.0 |
| haiku-lm | 2 | 0-0-2 | 0 | 2 | 125.4 |

Same shape: lm's loss as black was steady bleed to 3.2s over 73 plies (+2s increment does
not cover the medium tail either); its loss as white was a 150s retry storm on one move.

### 5+0 (blitz)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-lm | 4 | 3-0-1 | 3 | 1 | 3.3 |
| sonnet-ll | 2 | 1-0-1 | 1 | 1 | 3.2 |
| haiku-lm | 2 | 0-0-2 | 0 | 2 | 59.8 |

The direct pair split 1-1, and BOTH flags were stall-storm deaths with 4+ minutes still on
the flagged side's clock (a mover retry cascade — timeout-90s and no-legal-move rounds —
burning wall time while no move landed). 5+0 gives no clean effort signal of its own; the
lm points lead is two wins over haiku that ll never got to play. With zero increment, the
tail argument from 2+1/3+2 carries.

### 10+0 (rapid)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-lm | 4 | 2-2-0 | 3 | 0 | 3.4 |
| sonnet-ll | 2 | 0-2-0 | 1 | 0 | 3.2 |
| sonnet-mh | 2 | 0-0-2 | 0 | 2 | 12.9 |

sonnet-mh flagged both games — a 15.8s median sharp call against a 600s clock with no
increment is arithmetic, not luck. lm never flagged, beat mh twice, drew ll twice; one
136-ply draw ran lm's clock to 8.4s, so 10+0 is affordable for lm but without margin to
spare in marathons.

### 15+10 (rapid)

| config | games | W-D-L | points | flag losses | median model secs |
|---|---|---|---|---|---|
| sonnet-lm | 2 | 1-1-0 | 1.5 | 0 | 3.2 |
| sonnet-mh | 4 | 1-1-2 | 1.5 | 2 | 11.3 |
| sonnet-ll | 2 | 1-0-1 | 1 | 0 | 3.2 |

Even +10s does not cover an 11-16s median with a 64s p90: mh flagged twice of four. But the
one game mh survived to the end it won by CHECKMATE (game 024, 97 plies) — the only
on-the-board decisive result of the whole benchmark. High effort plays visibly better chess
when the clock lets it finish; under the 90s mover ceiling and real account pressure, none
of the standard controls does.

## Caveats, honestly

- Every decisive result except game 024 was a flag. On-the-board strength differences
  between sonnet efforts are mostly invisible at these controls; the clock dominates. That
  is the finding, not a defect of it (rule 17), but it means the pairs below are chosen for
  clock survival, not measured playing strength.
- The stall storms (repeated `timeout-90s` / `no-legal-move` attempt rounds, 240s+ of wall
  per storm) are account-pressure weather, not a property of any configuration — they hit
  sonnet-ll and sonnet-lm alike at 5+0. They are charged to the clock by design, and they
  make higher efforts strictly more exposed: the closer a call's honest latency sits to the
  90s attempt ceiling, the more often it becomes a storm. During much of the run only one
  account was walking; a healthier night would shrink the tails but not reorder them.
- Game 009's first attempt was interrupted mid-game by a session restart (the driver died
  with the chunk; wall clock kept running against black). It was replayed from scratch
  rather than recorded as a spurious flag; the interrupted record is archived in the repo's
  untracked `.scratch/bench-20260827/`, not on the ledger.
- Colour was rotated in every matchup. Small samples (2 games per matchup per control)
  mean single storms can decide a table row — read the latency table first, the W-D-L
  second.

## The verdict, and what was applied

Per-speed pair defaults (`chess_effort.SPEED_PAIRS`, overridable per rule 16b's knobs):

- **bullet (1+0, 2+1): low/low** — measured: lm bled out against ll twice at 2+1.
- **blitz (3+2, 5+0): low/low** — measured at 3+2; at 5+0 by the same tail arithmetic.
- **rapid (10+0, 15+10): low/medium** — lm never flagged in six rapid games, took 4.5 of
  6 points, and the increment/base absorbs medium's tail. High stays unaffordable: 4 flags
  in 6 rapid games.
- Untimed games keep the uniform low/medium pair exactly as the user adjudicated 2026-08-26.

Model, per control: **sonnet everywhere**. Haiku cannot play a timed move at any effort
(19-179s per call; 10 flags in 10 timed games it sat down for). Fable probes at ~3.7-3.9s —
playable — but it is the dear model, its allowance was already cooling on two of three
accounts during this very run, and 2026-08-15 is what letting a grind near it looks like;
nothing measured here says a chess move needs it. The per-speed model knobs
(`DESKCRAB_CHESS_MOVER_MODEL_<SPEED>`) stay unset — the mover's existing chain stands.

Generated alongside: 24 finished benchmark games fed the pattern store as every self-play
game does (reflex db grew from 4,022,272 to 4,755,456 bytes over the run), 893 counted
model-call attempts on the night's self-play ledger (benchmark games, probes, and the
night's earlier ordinary grind together, against the run's explicit 1200 ceiling), and
per-move bench rows in every game record for any deeper reading later.
