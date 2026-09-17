#!/bin/bash
# The tidy's own hand reported as an intruder's — specs/nightly.md rule 21h.
# The tidy job dispatches with a workdir that is NOT the drawer it edits:
# everything its brief touches lives under ~/.local/share/deskcrab/, so the
# watcher's job-workdir claim (rule 25c) covers none of its writes, and night
# after night the tidy came back as an alarm about an outside hand on the
# drawers — 03:12 on 2026-09-16, wants.md, the latest of the series. The cure
# is the brief's own leading step: a `crab touching` declaration over the five
# drawer paths, made BEFORE the first edit, with a window sized to the
# pipeline's real latencies — the 2026-09-16 job queued at 02:30 and only
# started at 03:10, so the 900-second default is the wrong scale entirely.
# Everything here is asserted against the brief the shipped unit's ExecStart
# actually dispatches — the tests/test_shelf_recheck.sh discipline — never a
# copy held by the test, so the unit cannot drift out from under it.
# Run: bash tests/test_tidy_touch_declaration.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

UNIT="$SANDBOX_REPO/systemd/deskcrab-tidy.service"
brief="$(sed -n 's/^ExecStart=.*crab job .* "\(.*\)"[[:space:]]*$/\1/p' "$UNIT")"
check "the shipped unit's ExecStart carries the tidy brief" [ -n "$brief" ]

echo "the brief declares before it edits:"
check "the brief contains a crab touching invocation" \
    contains "$brief" "crab touching"
check "the brief still has a step numbered 1 behind the declaration" \
    contains "$brief" '\n1. '
lead="${brief%%'\n1. '*}"
check "and the declaration stands before the step numbered 1" \
    contains "$lead" "crab touching"

echo
echo "the window comfortably outlasts a queued dispatch:"
w="$(sed -n 's/.*crab touching -w \([0-9][0-9]*\).*/\1/p' <<<"$brief")"
check "the declaration carries an explicit -w window" [ -n "$w" ]
check "of at least 1800 seconds, never the 900-second default" \
    [ "${w:-0}" -ge 1800 ]

echo
echo "the declaration names every drawer the brief edits:"
decl="$(grep -o "crab touching[^']*" <<<"$brief" | head -1)"
check "the invocation is quoted whole in the brief" [ -n "$decl" ]
# A space is appended before matching so the bare `wants` drawer is told apart
# from `wants.md` by the boundary that actually follows it in the invocation.
check "the wants shelf, wants.md" \
    contains "$decl " ".local/share/deskcrab/wants.md "
check "the wants document drawer beside it" \
    contains "$decl " ".local/share/deskcrab/wants "
check "the conduct drawer" \
    contains "$decl " ".local/share/deskcrab/conduct"
check "the engineering drawer" \
    contains "$decl " ".local/share/deskcrab/engineering"
check "and the journal" \
    contains "$decl " ".local/share/deskcrab/journal"
