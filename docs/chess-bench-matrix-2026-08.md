# Timed chess benchmark

**INCOMPLETE**

The timed study uses the existing matrix and native full-game driver, with up to three disjoint workers. `tools/chess-benchmark` derives the next games and completion from the recorded evidence. The study includes Astra; Spark remains permanently excluded from benchmark calls.

The full resumable plan and raw ledger are `~/.local/share/deskcrab/chess/selfplay/bench-matrix-20260828.json` and its `.jsonl` sibling. Invalid and pause-artifact sidecars remain alongside them. The running coordinator writes current progress to `~/.local/share/deskcrab/chess/selfplay/timed-completion-20260907/`. This checked-in report is a snapshot; regenerate it from the ledger when the run advances.

## Applied routing while comparisons are pending

| Control | Live state | Model | Quiet/sharp | Basis |
|---|---|---|---|---|
| 1+0, 2+1 | disabled | sonnet | low/low | No MEASURED configuration reliably finished bullet. |
| 3+2, 5+0 | enabled | gpt-5.3-codex-spark | low/low | EXPLICIT USER-SELECTED live-play trial; no benchmark clock-safety claim. |
| 10+0, 15+10 | enabled | opus | low/low | Provisional rapid route pending direct comparisons. |
| untimed | enabled | gpt-6-astra | low/medium | Local untimed model override; outside this timed study. |


Valid recorded games: 119. Excluded records: 253.

| Control | State | Selected model | Quiet / sharp |
|---|---|---|---|
| 15+10 | pending | none established | — |
| 10+0 | pending | none established | — |
| 5+0 | pending | none established | — |
| 3+2 | pending | none established | — |
| 2+1 | pending | none established | — |
| 1+0 | pending | none established | — |

## 15+10

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-615 (15+10, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-615 (15+10, flag).
- **sonnet**: low/low: passed, low/medium: passed, medium/medium: passed, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/high: recorded failure, selfplay-benchmatrix-20260828-569 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-569 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-569 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-569 (15+10, flag).
- **opus**: low/low: passed, low/medium: passed, medium/medium: passed, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/high: recorded failure, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
- **fable**: low/low: passed, low/medium: passed, medium/medium: passed, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/high: recorded failure, selfplay-benchmatrix-20260828-567 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-567 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-567 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-567 (15+10, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-571 (15+10, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-571 (15+10, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-611 (15+10, flag).
  low/medium: recorded failure, selfplay-benchmatrix-20260828-607 (15+10, flag).
  medium/medium: recorded failure, selfplay-benchmatrix-20260828-605 (15+10, flag).
  medium/high: recorded failure, selfplay-benchmatrix-20260828-597 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-597 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-597 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-597 (15+10, flag).
- **gpt-5.6-luna**: low/low: passed, low/medium: passed, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/medium: recorded failure, selfplay-benchmatrix-20260828-610 (15+10, flag).
  medium/high: recorded failure, selfplay-benchmatrix-20260828-599 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-599 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-599 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-599 (15+10, flag).
- **gpt-6-astra**: low/low: pending, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

Remaining comparisons:

- same-model: sonnet-low vs sonnet-low-medium; 2 game(s) missing.
- same-model: sonnet-low-medium vs sonnet-medium; 2 game(s) missing.
- same-model: opus-low vs opus-low-medium; 2 game(s) missing.
- same-model: opus-low vs opus-medium; 2 game(s) missing.
- same-model: opus-low-medium vs opus-medium; 2 game(s) missing.
- same-model: fable-low vs fable-low-medium; 2 game(s) missing.
- same-model: fable-low vs fable-medium; 2 game(s) missing.
- same-model: fable-low-medium vs fable-medium; 2 game(s) missing.
- same-model: gpt-5.6-luna-low vs gpt-5.6-luna-low-medium; 2 game(s) missing.
- gate: gpt-6-astra-low-low vs sonnet-low; 2 game(s) missing.

## 10+0

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-332 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
- **sonnet**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
- **opus**: low/low: passed, low/medium: passed, medium/medium: pending, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
- **fable**: low/low: passed, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  Selected pair: low/low.
  low/medium: recorded failure, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-336 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-488 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
- **gpt-5.6-luna**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-500 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
- **gpt-6-astra**: low/low: waiting, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

Remaining comparisons:

- gate: opus-medium vs sonnet-low; 2 game(s) missing.

## 5+0

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
- **sonnet**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
- **opus**: low/low: passed, low/medium: pending, medium/medium: waiting, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-565 (15+10, flag).
- **fable**: low/low: passed, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  Selected pair: low/low.
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
- **gpt-5.6-luna**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
- **gpt-6-astra**: low/low: waiting, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

Remaining comparisons:

- gate: opus-low-medium vs sonnet-low; 2 game(s) missing.

## 3+2

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
- **sonnet**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
- **opus**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-337 (3+2, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
- **fable**: low/low: passed, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  Selected pair: low/low.
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-561 (10+0, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
- **gpt-5.6-luna**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
- **gpt-6-astra**: low/low: waiting, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

## 2+1

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
- **sonnet**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
- **opus**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
- **fable**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: recorded failure, selfplay-benchmatrix-20260828-343 (2+1, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
- **gpt-5.6-luna**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
- **gpt-6-astra**: low/low: waiting, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

## 1+0

- **haiku**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-332 (10+0, flag).
- **sonnet**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-334 (10+0, flag, retry storm).
- **opus**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-337 (3+2, flag).
- **fable**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-343 (2+1, flag).
- **gpt-5.6-sol**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-336 (10+0, flag).
- **gpt-5.6-terra**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-488 (10+0, flag).
- **gpt-5.6-luna**: low/low: eliminated, low/medium: eliminated, medium/medium: eliminated, medium/high: eliminated, high/high: eliminated, high/xhigh: eliminated, xhigh/xhigh: eliminated.
  low/low: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  low/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/medium: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  medium/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/high: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  high/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
  xhigh/xhigh: inference from a clock loss, selfplay-benchmatrix-20260828-500 (10+0, flag).
- **gpt-6-astra**: low/low: waiting, low/medium: waiting, medium/medium: waiting, medium/high: waiting, high/high: waiting, high/xhigh: waiting, xhigh/xhigh: waiting.

## Excluded evidence

- selfplay-benchmatrix-20260828-001: manufactured fallback move.
- selfplay-benchmatrix-20260828-002: manufactured fallback move.
- selfplay-benchmatrix-20260828-003: manufactured fallback move.
- selfplay-benchmatrix-20260828-004: manufactured fallback move.
- selfplay-benchmatrix-20260828-005: manufactured fallback move.
- selfplay-benchmatrix-20260828-006: manufactured fallback move.
- selfplay-benchmatrix-20260828-007: manufactured fallback move.
- selfplay-benchmatrix-20260828-008: manufactured fallback move.
- selfplay-benchmatrix-20260828-009: manufactured fallback move.
- selfplay-benchmatrix-20260828-010: manufactured fallback move.
- selfplay-benchmatrix-20260828-011: manufactured fallback move.
- selfplay-benchmatrix-20260828-012: manufactured fallback move.
- selfplay-benchmatrix-20260828-013: manufactured fallback move.
- selfplay-benchmatrix-20260828-014: manufactured fallback move.
- selfplay-benchmatrix-20260828-015: manufactured fallback move.
- selfplay-benchmatrix-20260828-016: manufactured fallback move.
- selfplay-benchmatrix-20260828-017: manufactured fallback move.
- selfplay-benchmatrix-20260828-018: manufactured fallback move.
- selfplay-benchmatrix-20260828-019: manufactured fallback move.
- selfplay-benchmatrix-20260828-020: manufactured fallback move.
- selfplay-benchmatrix-20260828-021: manufactured fallback move.
- selfplay-benchmatrix-20260828-022: manufactured fallback move.
- selfplay-benchmatrix-20260828-023: manufactured fallback move.
- selfplay-benchmatrix-20260828-024: manufactured fallback move.
- selfplay-benchmatrix-20260828-025: manufactured fallback move.
- selfplay-benchmatrix-20260828-026: manufactured fallback move.
- selfplay-benchmatrix-20260828-027: manufactured fallback move.
- selfplay-benchmatrix-20260828-028: manufactured fallback move.
- selfplay-benchmatrix-20260828-029: manufactured fallback move.
- selfplay-benchmatrix-20260828-030: manufactured fallback move.
- selfplay-benchmatrix-20260828-031: manufactured fallback move.
- selfplay-benchmatrix-20260828-032: manufactured fallback move.
- selfplay-benchmatrix-20260828-033: manufactured fallback move.
- selfplay-benchmatrix-20260828-034: manufactured fallback move.
- selfplay-benchmatrix-20260828-035: manufactured fallback move.
- selfplay-benchmatrix-20260828-036: manufactured fallback move.
- selfplay-benchmatrix-20260828-037: manufactured fallback move.
- selfplay-benchmatrix-20260828-038: manufactured fallback move.
- selfplay-benchmatrix-20260828-039: manufactured fallback move.
- selfplay-benchmatrix-20260828-040: manufactured fallback move.
- selfplay-benchmatrix-20260828-041: manufactured fallback move.
- selfplay-benchmatrix-20260828-042: manufactured fallback move.
- selfplay-benchmatrix-20260828-043: manufactured fallback move.
- selfplay-benchmatrix-20260828-044: manufactured fallback move.
- selfplay-benchmatrix-20260828-045: manufactured fallback move.
- selfplay-benchmatrix-20260828-046: manufactured fallback move.
- selfplay-benchmatrix-20260828-047: manufactured fallback move.
- selfplay-benchmatrix-20260828-048: manufactured fallback move.
- selfplay-benchmatrix-20260828-049: manufactured fallback move.
- selfplay-benchmatrix-20260828-050: manufactured fallback move.
- selfplay-benchmatrix-20260828-051: manufactured fallback move.
- selfplay-benchmatrix-20260828-052: manufactured fallback move.
- selfplay-benchmatrix-20260828-053: manufactured fallback move.
- selfplay-benchmatrix-20260828-054: manufactured fallback move.
- selfplay-benchmatrix-20260828-055: manufactured fallback move.
- selfplay-benchmatrix-20260828-056: manufactured fallback move.
- selfplay-benchmatrix-20260828-057: manufactured fallback move.
- selfplay-benchmatrix-20260828-058: manufactured fallback move.
- selfplay-benchmatrix-20260828-059: manufactured fallback move.
- selfplay-benchmatrix-20260828-060: manufactured fallback move.
- selfplay-benchmatrix-20260828-061: manufactured fallback move.
- selfplay-benchmatrix-20260828-062: manufactured fallback move.
- selfplay-benchmatrix-20260828-063: manufactured fallback move.
- selfplay-benchmatrix-20260828-064: manufactured fallback move.
- selfplay-benchmatrix-20260828-065: manufactured fallback move.
- selfplay-benchmatrix-20260828-066: manufactured fallback move.
- selfplay-benchmatrix-20260828-067: manufactured fallback move.
- selfplay-benchmatrix-20260828-068: manufactured fallback move.
- selfplay-benchmatrix-20260828-069: manufactured fallback move.
- selfplay-benchmatrix-20260828-070: manufactured fallback move.
- selfplay-benchmatrix-20260828-071: manufactured fallback move.
- selfplay-benchmatrix-20260828-072: manufactured fallback move.
- selfplay-benchmatrix-20260828-073: manufactured fallback move.
- selfplay-benchmatrix-20260828-074: manufactured fallback move.
- selfplay-benchmatrix-20260828-075: manufactured fallback move.
- selfplay-benchmatrix-20260828-076: manufactured fallback move.
- selfplay-benchmatrix-20260828-077: manufactured fallback move.
- selfplay-benchmatrix-20260828-078: manufactured fallback move.
- selfplay-benchmatrix-20260828-079: manufactured fallback move.
- selfplay-benchmatrix-20260828-080: manufactured fallback move.
- selfplay-benchmatrix-20260828-082: manufactured fallback move.
- selfplay-benchmatrix-20260828-083: manufactured fallback move.
- selfplay-benchmatrix-20260828-084: manufactured fallback move.
- selfplay-benchmatrix-20260828-085: manufactured fallback move.
- selfplay-benchmatrix-20260828-086: manufactured fallback move.
- selfplay-benchmatrix-20260828-088: manufactured fallback move.
- selfplay-benchmatrix-20260828-089: manufactured fallback move.
- selfplay-benchmatrix-20260828-091: manufactured fallback move.
- selfplay-benchmatrix-20260828-092: manufactured fallback move.
- selfplay-benchmatrix-20260828-093: manufactured fallback move.
- selfplay-benchmatrix-20260828-095: manufactured fallback move.
- selfplay-benchmatrix-20260828-096: manufactured fallback move.
- selfplay-benchmatrix-20260828-097: manufactured fallback move.
- selfplay-benchmatrix-20260828-098: manufactured fallback move.
- selfplay-benchmatrix-20260828-099: manufactured fallback move.
- selfplay-benchmatrix-20260828-100: manufactured fallback move.
- selfplay-benchmatrix-20260828-101: manufactured fallback move.
- selfplay-benchmatrix-20260828-102: manufactured fallback move.
- selfplay-benchmatrix-20260828-103: undetermined no-attempt stall under the retired regime: the sonnet-low seat sat 184s to flag with zero recorded attempts — the cause (retired ceiling, account walk, or driver fault) is unknowable from the record, so the outcome is not play evidence (rule 20b).
- selfplay-benchmatrix-20260828-104: manufactured fallback move.
- selfplay-benchmatrix-20260828-105: manufactured fallback move.
- selfplay-benchmatrix-20260828-106: manufactured fallback move.
- selfplay-benchmatrix-20260828-107: manufactured fallback move.
- selfplay-benchmatrix-20260828-108: manufactured fallback move.
- selfplay-benchmatrix-20260828-109: manufactured fallback move.
- selfplay-benchmatrix-20260828-110: manufactured fallback move.
- selfplay-benchmatrix-20260828-111: manufactured fallback move.
- selfplay-benchmatrix-20260828-112: manufactured fallback move.
- selfplay-benchmatrix-20260828-113: manufactured fallback move.
- selfplay-benchmatrix-20260828-114: manufactured fallback move.
- selfplay-benchmatrix-20260828-115: manufactured fallback move.
- selfplay-benchmatrix-20260828-116: manufactured fallback move.
- selfplay-benchmatrix-20260828-117: manufactured fallback move.
- selfplay-benchmatrix-20260828-118: manufactured fallback move.
- selfplay-benchmatrix-20260828-119: manufactured fallback move.
- selfplay-benchmatrix-20260828-120: manufactured fallback move.
- selfplay-benchmatrix-20260828-122: manufactured fallback move.
- selfplay-benchmatrix-20260828-123: manufactured fallback move.
- selfplay-benchmatrix-20260828-124: manufactured fallback move.
- selfplay-benchmatrix-20260828-126: manufactured fallback move.
- selfplay-benchmatrix-20260828-131: manufactured fallback move.
- selfplay-benchmatrix-20260828-132: manufactured fallback move.
- selfplay-benchmatrix-20260828-133: manufactured fallback move.
- selfplay-benchmatrix-20260828-134: manufactured fallback move.
- selfplay-benchmatrix-20260828-135: manufactured fallback move.
- selfplay-benchmatrix-20260828-136: manufactured fallback move.
- selfplay-benchmatrix-20260828-137: manufactured fallback move.
- selfplay-benchmatrix-20260828-138: manufactured fallback move.
- selfplay-benchmatrix-20260828-139: manufactured fallback move.
- selfplay-benchmatrix-20260828-140: manufactured fallback move.
- selfplay-benchmatrix-20260828-141: manufactured fallback move.
- selfplay-benchmatrix-20260828-142: manufactured fallback move.
- selfplay-benchmatrix-20260828-143: manufactured fallback move.
- selfplay-benchmatrix-20260828-144: manufactured fallback move.
- selfplay-benchmatrix-20260828-145: manufactured fallback move.
- selfplay-benchmatrix-20260828-146: manufactured fallback move.
- selfplay-benchmatrix-20260828-147: manufactured fallback move.
- selfplay-benchmatrix-20260828-148: manufactured fallback move.
- selfplay-benchmatrix-20260828-149: manufactured fallback move.
- selfplay-benchmatrix-20260828-150: manufactured fallback move.
- selfplay-benchmatrix-20260828-151: manufactured fallback move.
- selfplay-benchmatrix-20260828-152: manufactured fallback move.
- selfplay-benchmatrix-20260828-153: manufactured fallback move.
- selfplay-benchmatrix-20260828-154: manufactured fallback move.
- selfplay-benchmatrix-20260828-155: manufactured fallback move.
- selfplay-benchmatrix-20260828-156: manufactured fallback move.
- selfplay-benchmatrix-20260828-157: manufactured fallback move.
- selfplay-benchmatrix-20260828-158: manufactured fallback move.
- selfplay-benchmatrix-20260828-159: manufactured fallback move.
- selfplay-benchmatrix-20260828-160: manufactured fallback move.
- selfplay-benchmatrix-20260828-162: pause artifact (rule 17's boundary): flag recorded 2026-08-30 23:27 EDT against white with 540,439ms of a 600,000ms base still stored; the driver had detoured into the appended top-up block 21:40-23:27 and model-calls-20260830.log shows the game's last attempt at 21:33:08 (ply 33) — 1h54m with zero attempts before the flag, and MOVE_TIMEOUT (240s) bounds any single in-play round, so no invocation could have spent that wall time playing. The flag priced the driver's absence, not sonnet-low's clock survival..
- selfplay-benchmatrix-20260828-163: manufactured fallback move.
- selfplay-benchmatrix-20260828-164: manufactured fallback move.
- selfplay-benchmatrix-20260828-165: manufactured fallback move.
- selfplay-benchmatrix-20260828-168: manufactured fallback move.
- selfplay-benchmatrix-20260828-171: manufactured fallback move.
- selfplay-benchmatrix-20260828-172: manufactured fallback move.
- selfplay-benchmatrix-20260828-173: manufactured fallback move.
- selfplay-benchmatrix-20260828-174: manufactured fallback move.
- selfplay-benchmatrix-20260828-175: manufactured fallback move.
- selfplay-benchmatrix-20260828-177: manufactured fallback move.
- selfplay-benchmatrix-20260828-178: manufactured fallback move.
- selfplay-benchmatrix-20260828-179: manufactured fallback move.
- selfplay-benchmatrix-20260828-180: manufactured fallback move.
- selfplay-benchmatrix-20260828-181: manufactured fallback move.
- selfplay-benchmatrix-20260828-182: manufactured fallback move.
- selfplay-benchmatrix-20260828-183: manufactured fallback move.
- selfplay-benchmatrix-20260828-184: manufactured fallback move.
- selfplay-benchmatrix-20260828-185: manufactured fallback move.
- selfplay-benchmatrix-20260828-186: manufactured fallback move.
- selfplay-benchmatrix-20260828-187: manufactured fallback move.
- selfplay-benchmatrix-20260828-188: manufactured fallback move.
- selfplay-benchmatrix-20260828-189: manufactured fallback move.
- selfplay-benchmatrix-20260828-190: manufactured fallback move.
- selfplay-benchmatrix-20260828-191: manufactured fallback move.
- selfplay-benchmatrix-20260828-192: manufactured fallback move.
- selfplay-benchmatrix-20260828-193: manufactured fallback move.
- selfplay-benchmatrix-20260828-194: manufactured fallback move.
- selfplay-benchmatrix-20260828-195: manufactured fallback move.
- selfplay-benchmatrix-20260828-196: manufactured fallback move.
- selfplay-benchmatrix-20260828-197: manufactured fallback move.
- selfplay-benchmatrix-20260828-198: manufactured fallback move.
- selfplay-benchmatrix-20260828-199: manufactured fallback move.
- selfplay-benchmatrix-20260828-200: manufactured fallback move.
- selfplay-benchmatrix-20260828-201: manufactured fallback move.
- selfplay-benchmatrix-20260828-210: manufactured fallback move.
- selfplay-benchmatrix-20260828-241: manufactured fallback move.
- selfplay-benchmatrix-20260828-242: manufactured fallback move.
- selfplay-benchmatrix-20260828-243: manufactured fallback move.
- selfplay-benchmatrix-20260828-244: manufactured fallback move.
- selfplay-benchmatrix-20260828-245: manufactured fallback move.
- selfplay-benchmatrix-20260828-246: manufactured fallback move.
- selfplay-benchmatrix-20260828-247: manufactured fallback move.
- selfplay-benchmatrix-20260828-248: manufactured fallback move.
- selfplay-benchmatrix-20260828-249: manufactured fallback move.
- selfplay-benchmatrix-20260828-250: manufactured fallback move.
- selfplay-benchmatrix-20260828-251: manufactured fallback move.
- selfplay-benchmatrix-20260828-252: manufactured fallback move.
- selfplay-benchmatrix-20260828-253: manufactured fallback move.
- selfplay-benchmatrix-20260828-254: manufactured fallback move.
- selfplay-benchmatrix-20260828-255: manufactured fallback move.
- selfplay-benchmatrix-20260828-256: manufactured fallback move.
- selfplay-benchmatrix-20260828-257: manufactured fallback move.
- selfplay-benchmatrix-20260828-258: manufactured fallback move.
- selfplay-benchmatrix-20260828-259: manufactured fallback move.
- selfplay-benchmatrix-20260828-260: manufactured fallback move.
- selfplay-benchmatrix-20260828-261: manufactured fallback move.
- selfplay-benchmatrix-20260828-262: manufactured fallback move.
- selfplay-benchmatrix-20260828-263: manufactured fallback move.
- selfplay-benchmatrix-20260828-264: manufactured fallback move.
- selfplay-benchmatrix-20260828-265: manufactured fallback move.
- selfplay-benchmatrix-20260828-266: manufactured fallback move.
- selfplay-benchmatrix-20260828-267: manufactured fallback move.
- selfplay-benchmatrix-20260828-268: manufactured fallback move.
- selfplay-benchmatrix-20260828-269: manufactured fallback move.
- selfplay-benchmatrix-20260828-270: manufactured fallback move.
- selfplay-benchmatrix-20260828-271: manufactured fallback move.
- selfplay-benchmatrix-20260828-272: manufactured fallback move.
- selfplay-benchmatrix-20260828-273: manufactured fallback move.
- selfplay-benchmatrix-20260828-274: manufactured fallback move.
- selfplay-benchmatrix-20260828-275: manufactured fallback move.
- selfplay-benchmatrix-20260828-276: manufactured fallback move.
- selfplay-benchmatrix-20260828-277: manufactured fallback move.
- selfplay-benchmatrix-20260828-278: manufactured fallback move.
- selfplay-benchmatrix-20260828-279: manufactured fallback move.
- selfplay-benchmatrix-20260828-280: manufactured fallback move.
- selfplay-benchmatrix-20260828-281: manufactured fallback move.
- selfplay-benchmatrix-20260828-282: manufactured fallback move.
- selfplay-benchmatrix-20260828-283: manufactured fallback move.
- selfplay-benchmatrix-20260828-284: manufactured fallback move.
- selfplay-benchmatrix-20260828-285: manufactured fallback move.
- selfplay-benchmatrix-20260828-286: manufactured fallback move.
- selfplay-benchmatrix-20260828-287: manufactured fallback move.
- selfplay-benchmatrix-20260828-288: manufactured fallback move.
- selfplay-benchmatrix-20260828-289: manufactured fallback move.
- selfplay-benchmatrix-20260828-303: manufactured fallback move.
- selfplay-benchmatrix-20260828-314: manufactured fallback move.
- selfplay-benchmatrix-20260828-317: manufactured fallback move.
- selfplay-benchmatrix-20260828-320: manufactured fallback move.
- selfplay-benchmatrix-20260828-321: manufactured fallback move.
- selfplay-benchmatrix-20260828-322: manufactured fallback move.
- selfplay-benchmatrix-20260828-323: manufactured fallback move.
- selfplay-benchmatrix-20260828-326: manufactured fallback move.
- selfplay-benchmatrix-20260828-327: manufactured fallback move.
- selfplay-benchmatrix-20260828-328: manufactured fallback move.
- selfplay-benchmatrix-20260828-511: wrong-login account interruption (rule 20b, user ruling 2026-08-31 23:3x): the gate pair ran through the regular codex account because the detached builder never inherited the conf's CODEX_BIN/CODEX_HOME; the completed games of that pair stand as valid play, but 511's flag fell only after THAT account's Spark subscription limit ran dry mid-game at 23:16:26 — an account-specific interruption that cannot establish whether the required second-login account could finish, so the outcome is not clock evidence; the ledger line stands, the slot is owed a replacement through the configured login.
- selfplay-benchmatrix-20260828-554: prompt-boundary defect: the mover showed SAN-labelled analysis before a free-text answer request, and Sonnet Low repeatedly returned illegal h6h3/h8h8 tokens by conflating those labels and source squares; the resulting retries and stall measure the defective harness, not model strength, reliability, or clock fitness, so the unfinished game is preserved but excluded and its same-seat slot is owed a clean replacement under the UCI-only whitelist prompt.
- selfplay-benchmatrix-20260828-564: live-game backend overlap caused a potentially contaminated clock loss: Opus High's final call began at 02:30:51 with 73.7 seconds left, browser-052 began at 02:31:44 and made Sonnet calls through the same Claude account, and 564 flagged at 02:32:05 without an answer; because the 21-second overlap may have caused the loss, the result is excluded and its exact colour seat is owed a clean replacement.
- selfplay-benchmatrix-20260828-572: wrong Codex login: the live driver lacked DeskCrab's CODEX_BIN and CODEX_HOME settings, so every Terra call used the regular ~/.local/bin/codex login instead of ~/.local/bin/codex2 with ~/.codex2; the result cannot establish the required ChatGPT account's timing or strength and its exact colour seat is owed a replacement.
- selfplay-benchmatrix-20260828-573: wrong Codex login: the live driver lacked DeskCrab's CODEX_BIN and CODEX_HOME settings, so every Terra call used the regular ~/.local/bin/codex login instead of ~/.local/bin/codex2 with ~/.codex2; the result cannot establish the required ChatGPT account's timing or strength and its exact colour seat is owed a replacement.
- selfplay-benchmatrix-20260828-574: wrong Codex login: the live driver lacked DeskCrab's CODEX_BIN and CODEX_HOME settings, so every Luna call used the regular ~/.local/bin/codex login instead of ~/.local/bin/codex2 with ~/.codex2; the result cannot establish the required ChatGPT account's timing or strength and its exact colour seat is owed a replacement.
- selfplay-benchmatrix-20260828-575: wrong Codex login: the live driver lacked DeskCrab's CODEX_BIN and CODEX_HOME settings, so every Luna call used the regular ~/.local/bin/codex login instead of ~/.local/bin/codex2 with ~/.codex2; the result cannot establish the required ChatGPT account's timing or strength and its exact colour seat is owed a replacement.
- selfplay-benchmatrix-20260828-582: wrong Codex login in an unfinished game: the live driver lacked DeskCrab's CODEX_BIN and CODEX_HOME settings, so Terra's recorded white moves used the regular ~/.local/bin/codex login before the account-limit interruption exposed the launch defect; the game cannot be resumed as required-account evidence and its exact colour seat is owed a clean replacement.

Results describe the recorded sample. A clock-safe winner has no valid recorded timing failure and has completed both colours and the required direct comparisons.
