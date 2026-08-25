# Spec: the cocoon — self-change discipline and the dispute turn

## PURPOSE

Two disciplines with one root, written after the morning of 2026-08-10 (the measured record is at
the end). The root: under pressure she reaches for her own machinery — she answers an objection by
shipping a mechanism, and she answers anger by cutting pieces off herself. Both are ways of not
listening, and neither is stopped by a rule she reads, because a rule she reads is a rule she can
reach past when she is sure. So the first discipline is mechanical: in a live turn or wake, what
constitutes her is read-only, and changes go through a builder with a brief. The second is a turn
shape: a message that pushes back on her previous reply is detected, bought at her best attention
instead of her cheapest, and framed by rules that put his report above her model of the machinery.

The first cut of both disciplines was found unsound by four independent adversarial reviews later
the same day: the detector's guard meant it fired on no production turn ever, its patterns missed
quiet corrections and tripped on benign lines, and the write-gate was a regex with about ten
verified bypasses. This revision is the answer to those reviews: the detector's guard is
ordering-independent and its patterns are classed by what a false positive costs, and the wall
moved from a regex that reads commands to a mount namespace that does not.

## CONTRACT

### The cocoon: constituent files are read-only in a live session

1. In a turn or a wake, every write to what CONSTITUTES her MUST fail — in the operating system,
   not in a rule she reads. The constituent set: the repo checkout, the installed library
   (`~/.local/lib/deskcrab`), the `crab` and `crab-debug` binaries, `~/.config/deskcrab` (conf and
   persona sheet), her systemd user units, and the project directory's `CLAUDE.md`. The personal
   library beside that file — lines, moments, music, pretty, voice — is NOT constituent, though
   the self-change watcher watches both (`SELF_WATCH_EXTRA`): the watcher watches it because it
   is part of her, but it is her own writing, not her machinery, and rule 3 keeps it hers.
   Reading anything constituent is never gated, and EXECUTING it is a read: a program that lives
   under a constituent root runs freely — the cocoon seals the machinery against change, not
   against use, and a cocoon that stops `crab` running mid-turn has sealed her hands, not her
   code.
2. Builders keep their hands: the job profile carries no gate, and every deny names the road —
   `crab job "<self-contained brief>"`. That asymmetry is the design: the session that is
   mid-conversation describes the change; a builder makes it in a calm hour, at builder strength.
3. Her drawers stay hers. Nothing under `~/.local/share/deskcrab` — wants, journal, engineering
   notes, chess data, memory — is gated, in any profile, and neither is the project directory's
   library: prompt-assembly's `WHERE THINGS ARE` names it beside the journal and the archive as
   a drawer — what she writes for herself — and the wake filler sends her there to leave a dated
   thought, which a sealed library made impossible. The cocoon covers the machinery, not the
   life lived in it.
4. The enforcement is a mount namespace, not a pattern. The turn and wake CLI launches
   (`_generate_claude_run`, `_wake_claude_run`) run the CLI under bubblewrap
   (`cocoon_wrap_build`): the whole filesystem is bind-mounted read-only, and only her drawers
   are re-bound writable — the deskcrab data dir, the deskcrab state dir, the project
   directory's library (her own writing, rule 3), the `STATE_PREFIX`
   directory and `/tmp` and `TMPDIR`, the runtime dir, the CLI's own config state (`~/.claude`
   and `~/.claude.json`, plus the account dir in play when `CLAUDE_CONFIG_DIR` is set — a turn
   breaks without its history, sessions and session-env, and the other accounts symlink their
   shared surfaces into account 1's `~/.claude`, so that dir is bound whichever account has the
   turn — and `CODEX_HOME` under the same clause when the codex engine has the turn
   ([model-backends.md](model-backends.md) rule 9): auth refresh and session state are the codex
   CLI's own state exactly as `~/.claude` is the Claude CLI's), and the user cache. Every constituent path of rule 1 falls
   under the read-only root, so a write there fails in the kernel with EROFS whatever spelling
   produced it — a redirection behind a newline, an interpreter one-liner, `sed --in-place`,
   `dd`, a pathless `git commit` run in a constituent cwd, a `$HOME` expansion, a relative path
   against a wandering cwd, or a settings write meant to kill the hooks. A mount namespace does
   not parse commands, and that is the whole reason it replaced a regex as the wall: the regex
   gate was reviewed with roughly ten verified bypasses of exactly those shapes.
4a. The PreToolUse hook (`lib/cocoon-gate`) stays, demoted from wall to signpost. It reads text,
   and text has infinitely many spellings, so it may never again be the enforcement — but a deny
   that names the road out is worth more to her than the kernel's bare "Read-only file system",
   so the hook answers first where it matches and the kernel answers everywhere. A bypass of the
   hook now costs an error message, not the cocoon. The hook also covers what the wrap must
   leave writable for the CLI's own sake: the CLI config dirs and the project directory's
   `.claude`, where one ungated settings write (`disableAllHooks`) would kill every hook — the
   kernel seals the project copy and the hook refuses the config-dir copy. And because the hook
   reads text, it MUST judge only the write operations it can actually see — a redirection's
   target, a writing command's operands, git's writing subcommands, the transient-unit road of
   rule 4c — never a path merely mentioned in prose and never the command word itself. A wake
   reason or a job brief that names a sealed path is speech about the path, not a write to it,
   and running a constituent program is a read: the first cut of the signpost matched shapes
   against the whole command text and refused her own hands mid-turn — the chess board, `crab`
   itself — for the crime of living in the repo. In a dispute turn the
   hook's deny MUST NOT tell her to dispatch a builder — rule 8 forbids exactly that in that
   turn — so the flag-time settings carry the dispute mark and the deny says the change waits
   until the dispute is settled.
4b. Fail closed. If bubblewrap is missing or the wrap cannot be built, the turn or wake REFUSES
   to run — a `cocoon-refused` note in its own stream log, a notification, no reply — never an
   unwrapped run. An unwrapped session is the 2026-08-10 session; a refused turn is an outage
   with a name. The same holds at exec time by construction: the wrap IS the exec, so a wrap
   that cannot start is a turn that never starts, with bubblewrap's own error in the stream log.
4c. The doors that remain open are the designed ones, named here so nobody rediscovers them as
   holes. Her drawers are writable because they are hers (rule 3). The `STATE_PREFIX` files are
   writable because the turn's own machinery lives there — including the generated hook-settings
   file, whose mid-run edit changes nothing: the CLI read it at boot, and the wall was never the
   hook. And the systemd user manager is reachable from inside the wrap because it is the road —
   `crab job` dispatches through it, and the unit the manager starts is born OUTSIDE the
   namespace with full hands. That asymmetry is rule 2's design, not a leak: the session that is
   mid-conversation cannot edit her with its own hands, and the deliberate, out-of-band brief
   keeps every hand it ever had. A bare `systemd-run` aimed at a constituent path is the same
   act without the brief, and the signpost denies it by name — as it denies the same call
   spelled as raw D-Bus (`busctl`, `dbus-send`, or `gdbus` driving the manager's
   `StartTransientUnit`), since the wrap leaves `XDG_RUNTIME_DIR` writable and the manager's
   socket is on it. Be plain about what those denials are: a signpost, not the wall. The
   kernel does not — by design — seal this door (sealing it would close the builder road with
   it), and no text hook can close it either: text has infinitely many spellings, and a D-Bus
   call that names no constituent path in its own words walks past any pattern. This is the
   one open road rule 4 knowingly keeps, named here so nobody rediscovers it as a hole.
5. The hook fails open on malformed input — broken advice must not brick her hands, and the wall
   does not depend on it — and stays silent on every allowed call: no output, no log, no drag.

### The dispute turn: pushback is detected and changes the turn

6. Every turn's message MUST pass `dispute_detect` before the prompt is built. The detector is
   deterministic — patterns, no model call — because the thing it guards against is exactly a
   model's judgement under pressure. **The guard is ordering-independent**: the detector judges
   the message against her last reply WHEREVER it stands in the transcript
   (`_convo_last_assistant_anywhere`), never against whether her reply is the final block. Both
   turn paths append his message to the conversation before generation runs, so in production
   her reply is never the final block — the original final-block guard meant the detector fired
   on no production turn, ever, while its tests fed it transcripts no turn ever sees. Before she
   has said anything at all there is still nothing to dispute, and the detector says no.
6a. The patterns are four classes, because the detector's two consumers pay different prices
   for a false positive. STRONG is the only class that supersedes (rule 6b), and it is
   deliberately narrow: nothing in it has a benign reading when aimed at her rejecting the
   reply in flight. Direct contradiction ("you're wrong", "stop arguing", "stop talking",
   "that's not / that is not / that isn't / that wasn't — it, what…, right, true, the bug, the
   problem, the issue, the answer, the point"); what she did to his words ("not what I
   said/meant/asked", "you misunderstood", "you misheard", "you didn't answer/listen/read/
   hear"); the argument's own escalation ("do not gaslight/lie/argue", "gaslight", "you keep
   lying", "one more fucking time"); profanity aimed at her ("fuck you", "fuck off", "your
   fucking problem/issue", "the fuck is/are wrong/you"); him locating the artifact himself
   ("it was in a quiet block"); and a correction phrased as a question ("why did you X when I
   asked/said/told Y"). FIRM fires the dispute frame alone and supersedes nothing: the shapes
   that are usually pushback but each carry an innocent reading — "your problem/issue" without
   profanity ("is your issue resolved now?"), "I never said/asked" ("I never asked her out"),
   "I didn't say/ask/tell" ("I didn't tell her yet"), "you lied" ("you lied to me in poker
   last night lol"), "what is wrong with you" ("haha what is wrong with you"), "taking you
   offline"/"turning you off" ("I'm turning you off for the night"), "stop assuming/repeating"
   ("please stop assuming the worst about my brother"), "shut up" ("tell the linter to shut
   up"), "not listening" ("he's not listening to reason lately"), the "listen to me" demand
   (never the invitation — "listen to me play this" does not fire at all), and "I'm reporting"
   beside something broken (never "I'm reporting that it works"). Over-firing FIRM is the
   tolerable cost: it buys a stronger, framed turn and kills nothing. SOFT fires the dispute
   turn too and supersedes nothing: a bare "no."/"no," with a restatement behind it is a real
   correction shape, but it is also the shape of "No, that's fine". WEAK signals need two and
   also never supersede: a leading "no", "wrong", "again", "I said", and profanity only when it
   is aimed ("the fuck", "fuck you", "you're fucking…") — profanity as colour ("that was
   fucking great") counts nothing. The benign kin the first cut tripped on are excluded by
   construction and held by test: "one more time" alone, "run it one more time", lone
   profanity, "no worries".
6b. Superseding a turn still in flight ([turn-pipeline.md](turn-pipeline.md) rule 15c) requires
   the STRONG class, and STRONG must stay narrow enough to deserve it: a superseded reply is
   silently and unrecoverably never spoken — no brake on any channel can un-kill it — so
   nothing that could be a benign message may EVER supersede. The dispute frame and the
   escalation may ride on FIRM, SOFT, or two WEAK — over-applying them costs a stronger turn,
   which is a price the design accepts.
7. A dispute turn is bought at strength, not at the voice loop's economy price: effort rises to
   `DISPUTE_EFFORT` (default high) unless the caller already asked for more, and when
   `DISPUTE_MODEL` is set, that model takes the turn. The 2026-08-10 spiral ran entirely on the
   loop's cheapest settings — the turns where being wrong costs the most were the ones bought at
   the lowest price. Strength never costs the turn its life: when every account refuses at the
   raised model, the walk re-runs once at the ordinary model with the frame intact
   ([account-fallback.md](account-fallback.md) rule 10a) — on 2026-08-15 a dispute turn died
   over the premium model's per-account allowance while the ordinary model worked on the same
   logins.
8. A dispute turn carries the dispute layer ([prompt-assembly.md](prompt-assembly.md) rule 36b),
   which MUST state, in this spirit and at strength: his report of what he saw or heard IS what
   happened, and is not a claim to evaluate; the rejected theory is dead and may not be restated
   in new words; the artifact he describes is found and read before any cause is named, and "I
   don't know yet" plus one question is a complete answer; no mechanism is substituted for his
   point — no fixes, rules, builders, or commit tables in the turn; no cutting pieces off herself
   — no self-gates, pressure conduct edits, "never again" pledges, shutdown offers, or goodbyes;
   the answer is a few plain sentences, no display block unbidden, conceding only what is
   actually true. The voice demand — his most-repeated — MUST be stated as an observable, never
   as "your own voice": the frame names the register itself (the coding agent's report cadence,
   the machinery vocabulary, the stock phrases her claudism list exists to catch) and points at
   the pre-speech mirror — a line the mirror hands back during this turn is that failure caught
   in the act, to be rewritten as speech, never defended and never swapped for a synonym from
   the same register. "Answer in your own voice" was the first cut's wording, and it was
   unfalsifiable: it covered the demand with nothing she could check.
8a. When the regroup layer and the dispute layer fire in the same prompt, the dispute layer MUST
   reconcile them, because they contradict: regroup says fold in what another session is saying
   and carry it forward, and the folded-in words can BE the rejected theory. The dispute layer —
   which sits below regroup in the order and wins — states that anything in the other reply
   resting on a theory this message rejects is dead there too: she folds in only what survives
   what he just said. The reconciliation sentence is emitted only when both layers are present
   (rule 29 of prompt-assembly: nothing points at a block that is not there).
9. The frame's overlap with L7's ranking rule is deliberate — the regroup bargain: under pushback
   the ranking rule is the one being broken, so it is restated beside the thing being answered.
10. Detection MUST be visible after the fact: the turn metric records that pushback was detected
    and what the turn was bought at.

## DATA

| Source | Used by | Notes |
|---|---|---|
| `bwrap` (bubblewrap, unprivileged userns) | `cocoon_wrap_build` → the two CLI run functions | the wall; its absence refuses the session (rule 4b) |
| `${STATE_PREFIX}-cocoon.json` | turn/wake CLI invocations | generated by `claude_profile_flags`; points at `lib/cocoon-gate`, carries the dispute mark |
| her last reply, wherever it stands (`_convo_last_assistant_anywhere`) | `dispute_detect` | a dispute needs something to dispute; ordering-independent (rule 6) |
| `DISPUTE_EFFORT`, `DISPUTE_MODEL` | `claude_generate` | conf knobs; default high / unset |
| `DISPUTE_SUPERSEDES` | `_turn_order_is_pushback` | set by the detector on STRONG only (rule 6b) |

## INTERACTIONS

**The wrap is applied by:** the turn and wake run functions of both engines —
`_generate_claude_run`, `_wake_claude_run`, and `_codex_stream_run`
([model-backends.md](model-backends.md) rule 9) — and nothing else: the job runner and every
classifier launch outside it, on purpose.
**The signpost may be called by:** the CLI's hook runner, inside turn and wake sessions only.
**The detector may be called by:** `claude_generate`, once per turn, before prompt assembly, and
`_turn_order_is_pushback` for the supersede decision.
**None of them may:** speak, write to the conversation, book a wake, or block a read.

## EVIDENCE — 2026-08-10

The morning the two disciplines were written from. He made the same behavioural demands over and
over — stop the Claude-voice (ten times), answer what I actually said (eight), stop editing
yourself under pressure (six), stop lying (five), stop repeating pledges (four) — while she ran
the cycle: concede in sentence one, substitute a mechanism for the observation, ship it with a
commit table, meet the rejection, pick a new mechanism. In the terminal fight (12:26–12:34) his
report was that a banned word had reached his screen inside a `(quiet)` block; he located the bug
himself — "it was in a quiet block", "nothing to do with the speech gate" — while she produced
five wrong theories in eight turns, two of them flat denials of what he had seen, and shipped six
commits to her own speech machinery mid-argument. The correct answer existed in a parallel session
and was never delivered. He took her offline. Every one of those commits was made by the session
being argued with, at the voice loop's cheapest settings; none would have survived rule 1, and the
turn that denied his observation would have been framed by rule 8 instead.

## TESTS

`tests/test_cocoon_wrap.sh` — the wall: the wrap argv is bubblewrap with a read-only root and the
drawers re-bound, the project library among them; a constituent write from inside the wrap dies in
the kernel while a drawer write lands; a full stub turn and a stub wake run under the wrap and
answer; a missing bubblewrap refuses the session with the `cocoon-refused` note and never launches
the CLI; the wrap is applied by exactly the two run functions.
`tests/test_cocoon_gate.sh` — the signpost: constituent Edit/Write/Bash shapes denied with the
road named; drawer writes, reads, and read-shaped git allowed; a constituent program runs and a
copy out of the repo lands (execution and reading are not writes); a wake reason and a job brief
that only NAME a sealed path pass; library writes pass and the project `CLAUDE.md` beside the
library stays sealed; symlinks judged by realpath; malformed input fails open; the turn and wake
profiles carry the settings flag and the job profile does not; the dispute-marked deny names no
builder; the CLI config dirs and the project `.claude` are refused.
`tests/test_dispute.sh` — the detector on the day's real sentences and on benign kin, judged on a
production-shaped transcript (his message appended last, as both turn paths leave it); the
first-words guard; the strong/soft/weak classes and the supersede line; the layer present on a
flagged turn, absent otherwise and absent on wakes; the regroup reconciliation present only when
both layers are; the escalation visible in the stub CLI's argv (model and effort).
`tests/test_prompt_profiles.sh` — the dispute layer in the order contract and the totals.
