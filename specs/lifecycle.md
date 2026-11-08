# Spec: lifecycle — seal and revive

## PURPOSE

Taking Beatrice fully down, and bringing her back, MUST each be one reliable command, not a
hand-typed run of `systemctl`, `pkill` and `wake-cancel`. On 2026-08-10 the by-hand version failed
twice in one session: a seal disabled the main wake timer but left a transient per-wake timer armed,
so a booked wake fired minutes after she was "offline"; and a revive ran `wake-restore`, which
stampeded a day's 27 stale wakes back the instant she came up. `crab seal` and `crab revive` are the
repair.

The word only means something if the command reaches every arm of hers that can spend an account.
Written against the units the repo shipped that day, it later sealed a system that still had the
portrait services up, eighty-two `notice-self` deferral timers armed to fire within the minute, and
the whole playing arm running on the game account. Hence the rules below: the shipped lists include
the portrait, the transient sweep goes by PREFIX rather than by the one `wake-` suffix, and the
playing arm goes down through its own door and is counted in the report.

## CONTRACT

### crab seal (alias: crab offline)

1. Seal MUST disable AND stop the two gate units — `deskcrab-serve.service` and
   `deskcrab-wake.timer` — so a login or reboot cannot re-arm them while she is meant to be down.
   Disable alone leaves them stopped-but-armed; stop alone leaves them enabled to return.
2. Seal MUST stop every other unit this repo ships: `deskcrab-chessweb.service`, the portrait
   services (`deskcrab-face-presence.service`, `deskcrab-face-openrsc.service`), the timers
   (`canary-selfchange`, `sleep`, `tidy`), and the `.path` watchers (`notice-selfchange`,
   `notice-transcriptions`).
3. Seal MUST stop every transient unit of hers BY PREFIX — `deskcrab-*.timer` and
   `deskcrab-*.service` — never by one suffix. A session books `deskcrab-wake-*`, a deferring
   self-change watcher books `deskcrab-notice-self-*` dozens at a time, a detached job books
   `deskcrab-job-*`, a turn child and the face broker book their own; a sweep written against the
   wake units alone leaves all the rest armed, and a disabled main timer does not touch them.
4. Seal MUST cancel every booked wake's RECORD, not merely stop its timer. A booking left on disk is
   brought back by `wake-restore`; cancelling the record is the step a by-hand seal forgets, and the
   omission is what left a wake alive on 2026-08-10. It calls `crab wake-cancel --all`.
5. Seal MUST take the playing arm down through its own door, `betty-openrsc stop`, and never by
   killing its process: the player unit carries `Restart=always`, so a kill IS a restart, and only
   the control unit stops it. That arm is the one that spends the game account, which is usually why
   she is being sealed at all. Seal passes its own turn origin, so a seal from the phone still takes
   the arm down, and skips the step silently when the command is not installed.
6. Seal MUST kill any live process of hers: a `crab wake`/`crab remote` session, its `tts-streamer`,
   a detached `job-runner`, a post-turn `memory.py judge-turn`, the `chessweb.py` server, the face
   broker, the detached portrait window (a process, not a unit), and the CLI mid-turn
   (`$CLAUDE_BIN -p`).
7. Seal MUST report what remains — live processes, loaded wake timers, booking records, playing-arm
   units up, gate enablement — and MUST exit non-zero if any of the first four is not zero. The
   playing arm is counted separately because its command line carries none of the words the process
   sweep greps for: a report blind to it reads "she is fully down" while the player is still
   spending. "Sealed" is a verified claim, never an assumption.
8. Seal MUST record whether the portrait window was open, so revive can put back exactly what seal
   closed and nothing more.
9. Seal MUST be idempotent: run on an already-sealed system it re-confirms zero and succeeds.

### crab revive (alias: crab online)

10. Revive MUST enable+start the gate units and start the services, timers and paths seal stopped.
    The face broker is not among them: it is spawned on demand by whatever first needs it.
11. Revive MUST reopen the portrait window only when seal recorded one open, and MUST clear the
    record once it has.
12. Revive MUST NOT run `wake-restore`. A clean revive follows a seal that cleared the bookings, so
    there is nothing stale to bring back, and the wake timer fires fresh on its own schedule.
    Restoring here is the 2026-08-10 stampede.
13. Revive MUST NOT start the playing arm. A sitting begins deliberately, with `betty-openrsc play`,
    against a session clock and a live objective; reviving into a game nobody asked for is the same
    stampede as the stale wakes, on the account that pays for it.
14. Revive MUST report how many core units came up and exit non-zero if any did not.

## DATA

`lib/lifecycle` holds `crab_seal`, `crab_revive`, `crab_seal_report`; `crab` dispatches
`seal`/`offline` and `revive`/`online` to them. The unit set is listed once in `lib/lifecycle`
(`_LC_GATES`, `_LC_SERVICES`, `_LC_TIMERS`, `_LC_PATHS`), and the playing arm's units and door once
beside them (`_LC_PLAY_UNITS`, `_lc_play_bin`), reading the same `BETTY_OPENRSC_*` env doors the
game player spec defines. The portrait-window record is one marker file,
`$XDG_STATE_HOME/deskcrab/sealed-face-window`.

## TESTS

`tests/test_lifecycle.sh` — the unit lists name every deskcrab unit the repo ships, the portrait
included; the transient sweep is by prefix, not by the wake suffix; seal stops the playing arm
through its door and revive never starts it; `crab_seal_report` returns success only when live
processes, wake timers, bookings and playing-arm units all read zero; `crab_revive` does not invoke
`wake-restore`.
