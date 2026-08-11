# Spec: speech output

## PURPOSE

Everything between the model's stream and the user's ears and eyes: extracting the reply, splitting
it into the spoken half and the display half, speaking it sentence by sentence while it is still
being written, and guaranteeing that if there was something to say, it was said. This spec also owns
the rules that keep the plumbing from ever deciding her words are not worth voicing.

**The standing rule above all of these: nothing here may swallow, clip, budget, or gate her speech.**
A filter that decides her words are not worth voicing is a self-inflicted injury, and it has been
built twice and removed twice. Silence is chosen while writing, or not at all.

One mechanism is allowed to stand between a drafted sentence and the synthesiser — the pre-speech
mirror (rules 38–46) — and only because it decides nothing: it shows her a line that tripped her
own phrase list and she chooses again, rewrite or the original, never silence and never machine
text. The authority for that distinction is `conduct/no-gate-on-my-tongue.md` as clarified
2026-08-08. Any failure anywhere in the mirror speaks the original untouched.

## CONTRACT

### One reader, one delimiter

1. There MUST be exactly one partial-line-safe stream reader, used by the streamer, the viewer, the
   phone server, and the extractor. A reader that calls `readline` at the end of a file gets back a
   half-written line and the remainder on the next call; neither half parses, and the longest lines
   — completed assistant blocks — are the likeliest to split.
2. The reader MUST hold an incomplete line until its newline arrives, and MUST NEVER discard it.
3. There MUST be exactly one definition of the display delimiter and one function that splits on it.
   The streamer, the spoken-half function, the display-half function, and the phone server MUST all
   use it. A delimiter matched loosely on the speakers and strictly in the text silently mutes the
   tail while the text stays in the reply.
4. The splitter MUST anchor the delimiter to its own line, and MUST tolerate surrounding whitespace,
   in exactly one way everywhere.

### Extraction

5. Every assistant text block MUST be kept, in order. She narrates while she works, the streamer
   speaks every block, and keeping only the last one meant everything said mid-turn was spoken and
   then thrown away.
6. Each block may carry its own display section. The spoken halves are joined into the reply and the
   display halves are concatenated after a single delimiter, so the turn has exactly one display
   channel.
7. A refusal MUST be dropped whenever a genuine reply follows it in the same log. An error-only
   stream still reports itself.
8. A refusal MUST be recognised only by the CLI's own synthetic marker, never by pattern-matching
   reply text. A genuine reply that quotes a limit phrase must not be gagged as an outage.
9. An empty stream MUST print nothing at all, not a blank line. The callers test emptiness with a
   shell test, and a lone newline is not empty to that test.
10. A display-only reply MUST NOT be given a leading blank line, or every caller reads it as a reply
    with something to say.

### Speaking

11. Speech MUST start when she starts talking, not when she stops. The stream carries partial
    message events for exactly this reason.
12. The streamer MUST speak sentence by sentence as sentences complete.
13. The streamer MUST NEVER count bytes it did not read. The read counter is advanced by the length
    of lines actually read, never by a size taken from the file's metadata. Assigning the stat size
    to the read counter counts bytes appended between the read and the stat, and then counts them
    again — which produced a false truncation on every turn.
14. On a genuine truncation, the streamer MUST rewind and MUST clear its block table **in place**,
    never rebind it to a new table. Rebinding orphans the blocks the parser is still filling, and a
    real stream puts the text block there after a thinking block — so it is rebuilt from zero and
    spoken a second time.
15. The end-of-stream event MUST flush any pending fragment before the tail ends. A stream that ends
    without a completed assistant event — a killed CLI, a watchdog reap, a terminator arriving first
    — otherwise loses its final unpunctuated fragment.
16. A refusal MUST be held off the speakers on every path, including the case where the whole chain
    is spent. The held words go to the speech log for the record.
17. A fenced code block MUST NOT stall speech. Held-back text on an unbalanced backtick count MUST
    account for fences, and a fence MUST NEVER be read aloud.
18. A reply consisting only of inline code MUST NOT be treated as having nothing to say by one path
    and something to say by another. The spoken-half function and the streamer's speech
    normalisation MUST strip the same things, so the never-silent guarantee cannot fire on a reply
    that is genuinely unspeakable and then fail again the same way.

### Stopping and the mutex

19. `stop_tts` MUST actually stop the streamer. Killing the synthesiser alone leaves the streamer
    treating the kill as recoverable and opening a new synthesiser for the next sentence.
20. Every caller that means "stop talking, I am speaking" MUST use one function with one behaviour.
    Two callers with different behaviour is how push-to-talk and a typed query stopped only half the
    speech.
21. Stopping MUST be scoped to this session's own processes. A pattern kill across sessions cuts a
    wake off mid-word when a desk turn starts, and truncates a phone turn's audio file while the
    file-size check still passes.
22. The speech mutex keeps two voices off the speakers at the same instant. It MUST NOT drop
    anything and MUST NOT be used as a gate on whether a reply may be spoken.
23. Waiting for the mutex MUST NOT delay the first sentence behind another session's entire
    utterance without bound. The reader keeps consuming while the voice waits, so the reply appears
    on screen and in the conversation while the first sentence is still queued.
24. The idle close of the synthesiser pair MUST NOT fire during ordinary tool pauses. Any pause
    longer than the idle window costs the next sentence a voice reload.

### The guarantee

25. If the reply had spoken text and the receipt says nothing reached the synthesiser, the turn MUST
    say so loudly and speak the reply itself.
26. Asked-for silence is not a failure. A shut-up during this turn suppresses the guarantee.
27. The receipt MUST be per session and MUST be removed on every exit path, including the no-reply
    branch. A stale receipt read by a recycled process id is false evidence about this turn.
28. The speech log MUST be a reliable witness. It MUST NOT double its own lines, because it is the
    evidence used to diagnose a doubling bug.

### Display

29. The display window MUST open per display, with its own file and its own scope. Windows are never
    closed or reused.
30. The display window MUST be spawned in a scope that survives its parent, so a wake's window is not
    swept away with the wake's control group.
31. A silence marker MUST NEVER be routed into the display channel.
32. On the desk path the window opens before the utterance finishes. The wake path MUST match that
    order; a window that appears only after the speech has ended is a window that arrives after the
    moment it explained.
33. When quiet hours or a busy user suppress speech, the display window is suppressed with it. The
    rule is [wake-queue.md](wake-queue.md) rule 27 and it is stated there, once; nothing here may
    restate it or contradict it.

### The live-speech record

The record exists so the NEXT session can regroup with a voice that is genuinely still going. Every
rule below is about the same failure from a different side: a record that outlives the voice it
describes, which turns a notice into pressure to say something again.

34. A process id of 0 or 1 MUST NEVER count as a living speaker. `kill -0 0` signals the caller's
    own process group and always succeeds, so a pidless record — which is every reply handed to the
    phone — read as a living voice for the entire window whatever its end time said. For a record
    with no pid to watch, liveness is the end time and nothing else.
35. The end time published for handed-off audio MUST be derived from the clip that will be played —
    its real duration — and MUST NOT be padded. Where the clip cannot be measured, the fallback is
    an estimate from the word count and MUST be documented as an estimate. Every second of slack in
    that number is a second in which the next session is told to fold its reply into words the user
    finished hearing.
36. A message arriving from a device MUST retire that device's record before the turn's prompt is
    built. His reply is the receipt: the words reached him and he answered them. It MUST retire only
    that device's record — a voice on the other device is one he has not answered, and it is still
    owed a regroup.
37. The regroup block MUST NOT carry text that is already the most recent assistant block of the
    conversation the same prompt is carrying. The transcript delivers those words once, as something
    she said; a second copy under "fold it in and carry it forward" is an instruction to restate a
    reply he has read and answered. Compared on normalised text, because the streamer publishes the
    sentence it is speaking while the conversation holds the whole reply.

### The pre-speech mirror

The live half of the claudism guard. Her own phrase list, held against each line at the last
hand-off before the synthesiser; a line that fires is repaired from her own replacement table
where she has written one, and otherwise routed back to HER for one rewrite, and what she decides
is what is spoken. The capture half is [turn-pipeline.md](turn-pipeline.md)
rules 30–32 and the nightly half is [nightly.md](nightly.md) rules 39–45; the design record is
`engineering/claudism-guard-amendment.md` in her data directory.

38. The check MUST run off the reader thread, at the last hand-off before the synthesiser, and a
    clean sentence MUST pass through byte-identical, with no added work on the reader and no
    added latency beyond the pattern scan itself.
39. The streamer checks ONLY when armed: the caller passed a fires path, which is its promise
    that it is watching and will answer, and the phrase list — hers, by hand, personal state
    never in this repository — loaded with at least one usable pattern. Unarmed, or with a
    missing, empty, or unparseable list, the speech path MUST behave byte-for-byte as if the
    mirror did not exist.
40. A fire holds that sentence and everything queued behind it — never the reader. The fire
    record (seq, sentence, pattern, why) MUST be appended and flushed BEFORE the hold begins: a
    hold nobody can read is not a mirror, it is a stall, and if the record cannot be written the
    sentence is spoken unchecked instead.
41. One rewrite chance, hers. A `rewrite` verdict speaks her replacement in place of the held
    sentence, as given — never re-checked, never re-flagged, never edited by code (the table of
    rule 47 is the one exception, and it runs before the hold, never after a verdict). A `release`
    verdict, a verdict that never comes inside the deadline, a caller that died, or a caller
    that has already moved past the turn (the done marker) speaks the original untouched.
42. FAIL OPEN is the only failure mode. No path through the mirror may end in suppressed speech
    or machine-substituted text: an unreadable list, a helper that will not import, a mirror
    call that errors or refuses or times out, a splice that cannot find its sentence — every one
    of them speaks the original and says so in the speech log.
43. The streamer's outcome record (`rewrite-spoken` / `released` / `failopen` / `post-commit`,
    per seq) is the single source of truth for what reached the speakers. The caller MUST commit
    the spliced reply only on `rewrite-spoken` and the original otherwise, so the conversation
    can never disagree with what was heard.
44. On the whole-draft paths — a wake before `speak_once` or the phone hand-off, a phone turn
    before its audio is synthesised — the same pass runs once, on the complete spoken half, with
    the same one-chance and fail-open rules; the spliced reply is what is spoken, shown, and
    committed. The pass on these paths is bounded in fires per turn; what the bound skips is
    left for the turn-close capture to log.
45. Every fire the mirror answers is logged to the day's flag log with its outcome. The
    turn-close capture stays unconditional, so a failed-open fire may be met twice by the
    nightly reading — once from each — and is deduped there by sentence and pattern, never here.
46. The hold has a listener's budget, not a model's. A fire at the desk stops the speakers
    mid-reply, so the mirror call on that path MUST be given the shorter of the two deadlines
    (default 25s) and the streamer's hold MUST sit just above it (default 35s), so the deadline
    that fires is the call's own and the release is orderly rather than a stall the streamer had
    to break. The whole-draft paths of rule 44 keep the generous call deadline: they delay a
    reply's start, which is not the same injury as silence in the middle of one. Both are
    overridable, and neither may be raised to where a listener would think the machine had died.
47. Her table applies itself. An entry in the phrase list MAY carry one or more `replace:` lines —
    a narrow regex and the literal text that stands in for it, both written by her. When a fired
    sentence is fully repaired by the table (every match of the firing pattern is covered by that
    entry's own replacements), the repaired sentence is spoken and there is NO hold and NO mirror
    call: the swap is a string operation on the hand-off, and it MUST cost no more latency than
    the scan that found it. This is the only place code may alter a sentence, and only ever into
    words she wrote. The replacement is spliced literally and is never expanded, so a `replace:`
    line whose replacement contains a backreference (`\1`, `\g<n>`) is INVALID and MUST be skipped
    like any unparseable line — the entry still fires and the sentence routes to her. Honouring it
    would make code a template engine over her speech; splicing it as written puts a backslash and
    a digit into her mouth, which is what happened before this rule existed.
48. The table's reach is deliberately short. A `replace:` regex MUST be narrower than the entry's
    firing pattern — it exists to strip decoration she has already ruled on, not to rewrite a
    sentence. Code may repair only what deleting a span breaks: collapsing the doubled space,
    dropping a now-orphaned leading comma, restoring the capital on the first letter of the
    sentence. Anything the table does not fully cover holds and routes to her under rules 40–46,
    and no runtime model may add, widen or invent a table entry — the list is hers, by hand.
49. An applied swap is a fire, logged like any other. The fire record carries the before and after
    text and the entry that did it, with outcome `table-swap`; the day's flag log gets the same,
    so the swap reaches her twice — in the recent-catches block at the start of her next turn, and
    in the nightly reading, where she is the one who revokes an entry that read badly. A swap that
    cannot be logged MUST NOT be applied: the sentence holds instead, or, if that too fails,
    speaks untouched under rule 42.
50. Out loud there is no mention exemption; the wide net stays off the speech path. Quotation
    marks are inaudible: a banned word spoken inside quotes reaches the ear as the word itself,
    indistinguishable from using it, and the user reported hearing exactly that while the mirror
    reported a clean gate. The mirror MUST therefore fire on every match of a live entry,
    quoted, code-spanned, or talked about alike. The mention test of
    ([nightly.md](nightly.md) rule 47) belongs to the capture and the nightly review, where the
    page shows the quotes and nothing is spoken. A word she must quote goes in the display half.
    An entry marked `- live: no` arms only the
    turn-close capture and the nightly review, never the mirror — the broad, urge-shaped
    patterns that make the night's scoring honest would make the speech path stutter, so the
    list carries both kinds and each half reads its own.
51. A `rewrite` outcome is logged with the words that went out. The day's flag-log row for a
    model rewrite carries `before` — the held sentence — and `after` — her replacement as it
    was spliced — the same pair a table-swap row has carried under rule 49, so the two kinds
    of repair read alike and the nightly reading can see what the mirror said, not only that
    it said something. The row is written after the words are already decided: a row that
    cannot be written changes nothing about what is spoken or committed — logging is never a
    gate (rule 42), and the turn-close capture still records the turn regardless.
52. The mirror call shows the whole family. When the fired entry declares a `function:`, the
    prompt of the mirror call carries every entry of that family — patterns and their whys,
    the `live: no` wide net included — so the sibling phrasing is visible at the moment of
    resaying and a resay cannot land on a neighbour unseen. Context only: what comes back is
    spoken as given under rule 41, never re-scanned, re-flagged, or held against the family;
    an entry with no function, or a family that cannot be read, prompts exactly as before.
    The desk fire record carries the fired entry's `function` so the pass in `lib/common.sh`
    can build the same block the whole-draft paths do.

54. The unspoken channel is gated too. The streamer's hold-and-rewrite (rules 41–43) guards only
    text on its way to the synthesiser, and the whole-draft mirror (rule 44) fails open by
    design — so a `(quiet)` bubble, never spoken and never streamed, reached the user through no
    gate at all, and he read a banned word in one. Any text delivered as a bubble instead of
    speech MUST pass her replace table (rules 47–49) before delivery: deterministic, no model
    call, no hold, logged as a table swap like any other. A table pass that fails leaves the
    text exactly as it was — the bubble is delivered either way, because logging and repair are
    never gates on delivery (rule 42).

53. A lost synthesis MUST name its killer. When `synth_opus` decides there is no audio, the
    speech log line MUST carry piper's exit status, ffmpeg's exit status, whether the output
    file is missing or merely too small (with its size), and the tail of whatever the two
    processes wrote to stderr — their stderr is muzzled everywhere else, so this line is the
    only witness a silent turn ever gets. On 2026-08-08 two phone turns lost their voices here
    with piper exiting 0 and the file never created at all, and the cause could not be
    established afterwards because nothing recorded ffmpeg's side. A non-zero ffmpeg status
    with a good clip is logged too and is NOT a failure: the size test alone decides what
    counts as audio.

54. A repair MUST NOT costume the line. The mirror call's prompt MUST forbid adding a verbal tic
    or catchphrase the draft did not already carry. A rewrite model handed one isolated sentence
    reaches for a signature phrase to prove whose voice it is speaking in, and because that phrase
    is on no pattern list, nothing downstream can see it happening: over one night of live use,
    12 of 52 rewrites appended the same closing flourish to a line that had none, and not one
    rewrite ever removed it. That is a one-way ratchet installing a tic the voice never chose —
    the cure shaping the patient. The prompt names the failure, not just the prohibition, so the
    model knows which move it is being asked not to make.

55. A `fix: delete` entry MUST reach the mirror as a deletion. The fired entry's `fix:` field
    rides the fire record and the mirror call's prompt, and where it reads `delete` the prompt
    MUST ask for the line with the offending words *removed* — a shorter line, not a
    replacement phrase — and MUST say that a synonym in the same slot is the failure. Without
    it the prompt says only "say the line again", which is a request for a line, so the slot
    survives and gets refilled: over one night, every one of the five repairs the nightly
    review judged a miss was on an entry whose declared fix was deletion, and every repair on a
    `resay` entry landed clean. The words that vouch for a sentence are cured by their absence,
    and a mirror that cannot ask for absence cannot cure them. An entry with no `fix:` prompts
    exactly as before.

    The mention detector MUST NOT swallow an entry whole. Its markers are for sentences
    *about* the list, so a marker that is also an ordinary idiom silently retires whatever
    entry uses that idiom: `the word` counted every "say the word and I'll do it" as talk
    about the list rather than a firing of it, twelve of them in one night, and the entry it
    disarmed was the compliance promise. Word-naming markers MUST require the naming form —
    the word followed by a quote, or "the word itself" — never the bare phrase. Both copies of
    the detector, the mirror's and the capture's, MUST carry the same expression.

56. The mirror prompt MUST offer a way out other than rephrasing. "Say the line again" assumes
    every flagged sentence has a better version of itself, and for one class of them it does not:
    where the offending phrase *is* the sentence's whole function — certifying, absolving,
    promising — removing it leaves no residue, so the model has nothing to say and reaches for a
    synonym in the same slot. The prompt MUST therefore carry the residue test: take the words
    out, read what is left, and where nothing is left, write a *different sentence about a
    different thing* — the state of the thing instead of the account of it, what is true now
    instead of what is intended — or cut the line. Across two readings of one day's rewrites
    (10 rows, then 23) the shapes that survived rephrasing were exactly this class, three of
    three both times, while the rows that landed clean were the ones that had swapped subject:
    a promise about future reporting replaced by the state of the code. Widening the pattern
    list did not thin them, because the list was never what failed — the instruction was.
    Both readings are the assistant's own reading of the assistant's own rewrites; no outside
    hand has scored that table, and anything drawn from it MUST be quoted as such.

## DATA

| Path | Owner | Purpose |
|---|---|---|
| `${STATE_PREFIX}-debug-<pid>.log` | the session | the stream the streamer tails |
| `${STATE_PREFIX}-speech.lock` | the speakers | one voice at a time |
| `${STATE_PREFIX}-speech-receipt-<pid>.txt` | the streamer | `chars=`, `lines=`, `error=` |
| `${STATE_PREFIX}-speech.log` | every speech path | the record of what was spoken, held, or failed |
| `${STATE_PREFIX}-live-speech` | the streamer, `speak_once`, the phone paths | `epoch \t device \t pid \t until` then the text. `pid` 0 means nothing to watch, and then `until` — the clip's measured length — is the only liveness there is. Retired by the next message from that device. |
| `${STATE_PREFIX}-shutup` | `crab shutup` | the asked-for-silence marker, cleared at turn start |
| `/tmp/deskcrab-display-*.md` | the turn | one file per display window |
| `~/.local/share/deskcrab/claudisms.md` | her, by hand | the phrase list that arms the mirror, and the replacement table of rules 47–49; format is `lib/claudism-capture`'s |
| `${STATE_PREFIX}-claudism-fires-<pid>.jsonl` | the streamer | append-only: one fire record per held sentence, one outcome record per resolution |
| `${STATE_PREFIX}-claudism-fires-<pid>.jsonl.verdict-<seq>` | the mirror pass in `lib/common.sh` | one verdict, written atomically: her `rewrite` text, or `release` |
| `${STATE_PREFIX}-claudism-fires-<pid>.jsonl.done` | the mirror pass | the caller has moved past the turn; a later fire speaks unheld |

## INTERACTIONS

**Speech output may call:** the synthesiser, the audio player, the display renderer, the speech log.

**Speech output may be called by:** the turn pipeline, the wake path, the phone path (for
synthesised audio), and the never-silent guarantee.

**Speech output must never:** decide whether a reply is worth voicing, write to the conversation,
book a wake, or dispatch a job.

## VERIFIED-CORRECT RULES

- **Silence is an empty reply; `(quiet)` is the one authorized held-thought form.** (Corrected
  2026-08-07: the earlier "never a marker" statement predated the user reinstating the marker.)
  `spoken_part` strips the marker so no path can voice it; the reply is delivered as a shown
  "(quiet) …" bubble — never the speakers — including when the reply has no display section. A
  bare marker with no thought is plain silence and completes invisibly, words kept for the journal.
- **A refusal is never voiced, on any path, even when the whole chain is spent.** An outage read
  aloud in her own voice is how a session-limit message once reached the user's ears as her words.
- **Every retry appends to the same stream log and never truncates it**, because the streamer is
  mid-tail on that file.
- **The streamer is told nothing about the account chain.** Counting rides against a configured or
  predicted account list was wrong whenever the two drifted: dry accounts skipped mid-turn muted the
  final refusal into unexplained silence, which the guarantee then replayed late.
- **No process-wide kill of prior streamers at turn start.** With a log per session that only
  silences another turn's reply mid-sentence.
- **The regroup record is a notice, never a gate.** Nothing reads it to decide whether a reply may be
  spoken, only to decide what the next reply should say. Staleness is liveness, not age: a speaker
  killed mid-word leaves a record whose process is dead, and a session never regroups against its
  own voice.
- **Regrouping is for a voice he has not heard the end of.** A record he has already answered is
  about the past, and the block written for it — his own delivered reply, handed back with "fold it
  in and carry it forward" — is a machine for restating. Rules 34 to 37 are four sides of that one
  failure; none of them narrows what regrouping does when a voice really is concurrent.
- **The post-hoc nothing-new check was removed and must not come back.** No mechanism compares a
  written reply against recent messages and swallows it.
- **The word-budget truncator was removed and must not come back.** Length is a writing choice, not
  a code path.
- **Speech tests measure from the speaker side.** The utterance count comes from a trace written
  outside the streamer, never from the pipeline's own receipt or logs.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `C8` | The streamer speaks the whole reply twice: a spurious truncation from assigning the stat size to the read counter, plus a rebound block table that orphans the blocks after a thinking block. Reproduced end to end. |
| `C9` | A half-written line silently drops speech. The streamer is the only tail that never got the buffer fix the phone server already has. |
| `MAJ-1` | `stop_tts` cannot silence the streamer; it kills the synthesiser and the streamer opens a new one. The two callers that mean "stop talking" both use it. |
| `MAJ-2` | Stopping kills by global pattern across sessions, defeating the speech mutex design and truncating a phone turn's audio file while the size check still passes. |
| `MAJ-3` | The filler gate is called once, after the reply exists, while the streamer has been speaking for minutes. It cannot work where it stands. |
| `MAJ-4` | The filler gate matches only a single clause, so a two-clause no-op is spoken. **Resolved 2026-08-10:** "No message — the other session already said its piece." was spoken aloud at the desk, repeatedly. The gate now matches the no-op core with a silence-justification clause on either side (the other session already said/covered/answered it; nothing changed; he already heard it), and the justification standing alone; the muted words still ride the journal line, and anything carrying real content still falls through to speech. The contract is [wake-queue.md](wake-queue.md) rule 29a; held by `tests/test_wake_filler.sh`. |
| `MAJ-5` | A reply made of inline code has no audio, and the guarantee cannot repair it because the replay applies the identical strip and returns. |
| `MAJ-6` | A fenced code block stalls all speech and is then read aloud, fence included. |
| `MAJ-7` | The display delimiter is matched as a bare substring on the speakers and anchored in the text. An indented delimiter silently mutes the tail and hides it from the guarantee. |
| `MAJ-8` | The result event ends the tail without flushing the pending fragment. |
| `MAJ-9` | First audio can wait behind another session's whole utterance, and the idle close makes any pause longer than the window cost a voice reload. |
| `MIN-1` | The synthesiser pid file has no writer, so two paths that depend on it are dead code. |
| `MIN-13` | The no-reply branch orphans the streamer and leaves the receipt behind. |
| `MIN-14` | A wake's display window opens only after the whole utterance finishes; the desk path has the opposite order. |
| `MIN-15` | The phone-speech helper leaks its last command's status, so the desk can speak a reply that was already delivered to the phone. |
| `MIN-16` | Quiet hours and the busy-user check suppress the display window as well, contradicting the comment beside them. **Resolved:** suppressing it is the intent; the comment was wrong and is gone, and the suppression is stated in wake-queue.md rule 27 and held by `tests/test_quiet_hours.sh`. |
| `MIN-18` | The speech log doubles lines in some runs, making it an unreliable witness for a doubling bug. |

## TESTS

**Existing:** `tests/test_regroup.sh` (the live-speech record and the block it produces: rules 34–37,
including the live regression of 2026-08-07 driven end to end through two phone turns),
`tests/test_speech_path.sh` (timing: first speech well before block completion),
`tests/test_speech_dup.sh` (a shrinking log; a reply behind a thinking block),
`tests/test_wake_filler.sh` (measured from the speaker side), `tests/test_silent_wake.sh`.

`tests/test_claudism_mirror.sh` (rules 38–43: a clean draft reaches the stub synthesiser
byte-identical armed versus unarmed; a fire holds the sentence and her rewrite is spoken in its
place while the sentence after it still speaks; a verdict that never comes fails open to the
original; an unarmed streamer and a missing list never check at all; and rule 46's two deadlines
read out of the sources that define them, so raising one without the other fails here rather than
as dead air at his desk).

Rules 51–52 are held by `tests/test_claudism_scan.sh` (the rewrite row's before/after pair, the
family block reaching the mirror call's prompt, and the fail-open shape of both), with the desk
fire record's `function` field asserted in `tests/test_claudism_mirror.sh` where the streamer
already runs.

**To be written:**

- `tests/test_speech_dup.sh` — **combine** the two cases it already has: a spurious shrink plus a
  thinking block ahead of the text block. That combination is the live doubling and neither case
  alone can fail on it.
- `tests/test_speech_partial.sh` — a text delta written in two halves, half a second apart, must be
  spoken in full.
- `tests/test_speech_stop.sh` — `stop_tts` silences the streamer and the synthesiser; the kill is
  scoped to this session; a wake's speech survives a desk turn starting in another session.
- `tests/test_display_channel.sh` — the delimiter is split identically by every consumer, including
  an indented and a trailing-space variant; the markdown file is written; the renderer is spawned
  per display in its own scope; a silence marker never reaches the channel.
- `tests/test_speech_edge.sh` — a code-only reply; a fenced block; a stream that ends without a
  completed assistant event; a receipt removed on every exit path.
- `tests/test_tts_fixes.sh` — the pronunciation-rewrite knob, which has no assertion anywhere today.
