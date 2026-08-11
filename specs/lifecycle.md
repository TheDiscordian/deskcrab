# Spec: lifecycle — seal and revive

## PURPOSE

Taking Beatrice fully down, and bringing her back, MUST each be one reliable command, not a
hand-typed run of `systemctl`, `pkill` and `wake-cancel`. On 2026-08-10 the by-hand version failed
twice in one session: a seal disabled the main wake timer but left a transient per-wake timer armed,
so a booked wake fired minutes after she was "offline"; and a revive ran `wake-restore`, which
stampeded a day's 27 stale wakes back the instant she came up. `crab seal` and `crab revive` are the
repair.

## CONTRACT

### crab seal (alias: crab offline)

1. Seal MUST disable AND stop the two gate units — `deskcrab-serve.service` and
   `deskcrab-wake.timer` — so a login or reboot cannot re-arm them while she is meant to be down.
   Disable alone leaves them stopped-but-armed; stop alone leaves them enabled to return.
2. Seal MUST stop every other unit: `deskcrab-chessweb.service`, the timers (`canary-selfchange`,
   `sleep`, `tidy`), and the `.path` watchers (`notice-selfchange`, `notice-transcriptions`).
3. Seal MUST stop every transient per-wake unit (`deskcrab-wake-*.timer`/`.service`) — a session or
   `wake-restore` books these, and a disabled main timer does not touch them.
4. Seal MUST cancel every booked wake's RECORD, not merely stop its timer. A booking left on disk is
   brought back by `wake-restore`; cancelling the record is the step a by-hand seal forgets, and the
   omission is what left a wake alive on 2026-08-10. It calls `crab wake-cancel --all`.
5. Seal MUST kill any live process of hers: a `crab wake`/`crab remote` session, its `tts-streamer`,
   a detached `job-runner`, a post-turn `memory.py judge-turn`, the `chessweb.py` server, and the
   CLI mid-turn (`$CLAUDE_BIN -p`).
6. Seal MUST report what remains — live processes, loaded wake timers, booking records, gate
   enablement — and MUST exit non-zero if any of the first three is not zero. "Sealed" is a verified
   claim, never an assumption.
7. Seal MUST be idempotent: run on an already-sealed system it re-confirms zero and succeeds.

### crab revive (alias: crab online)

8. Revive MUST enable+start the gate units and start the services, timers and paths seal stopped.
9. Revive MUST NOT run `wake-restore`. A clean revive follows a seal that cleared the bookings, so
   there is nothing stale to bring back, and the wake timer fires fresh on its own schedule.
   Restoring here is the 2026-08-10 stampede.
10. Revive MUST report how many core units came up and exit non-zero if any did not.

## DATA

`lib/lifecycle` holds `crab_seal`, `crab_revive`, `crab_seal_report`; `crab` dispatches
`seal`/`offline` and `revive`/`online` to them. The unit set is listed once in `lib/lifecycle`
(`_LC_GATES`, `_LC_SERVICES`, `_LC_TIMERS`, `_LC_PATHS`).

## TESTS

`tests/test_lifecycle.sh` — the unit lists name every deskcrab unit the repo ships; `crab_seal_report`
returns success only when live processes, wake timers and bookings all read zero; `crab_revive` does
not invoke `wake-restore`.
