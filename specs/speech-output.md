# Spec: speech output

## PURPOSE

Everything between the model's stream and the user's ears and eyes: extracting the reply, splitting
it into the spoken half and the display half, speaking it sentence by sentence while it is still
being written, and guaranteeing that if there was something to say, it was said. This spec also owns
the rules that keep the plumbing from ever deciding her words are not worth voicing.

**The standing rule above all of these: nothing here may swallow, clip, budget, or gate her speech.**
A filter that decides her words are not worth voicing is a self-inflicted injury, and it has been
built twice and removed twice. Silence is chosen while writing, or not at all.

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

## DATA

| Path | Owner | Purpose |
|---|---|---|
| `${STATE_PREFIX}-debug-<pid>.log` | the session | the stream the streamer tails |
| `${STATE_PREFIX}-speech.lock` | the speakers | one voice at a time |
| `${STATE_PREFIX}-speech-receipt-<pid>.txt` | the streamer | `chars=`, `lines=`, `error=` |
| `${STATE_PREFIX}-speech.log` | every speech path | the record of what was spoken, held, or failed |
| `${STATE_PREFIX}-live-speech` | the streamer, `speak_once`, the phone paths | `epoch \t device \t pid \t until` then the text |
| `${STATE_PREFIX}-shutup` | `crab shutup` | the asked-for-silence marker, cleared at turn start |
| `/tmp/deskcrab-display-*.md` | the turn | one file per display window |

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
| `MAJ-4` | The filler gate matches only a single clause, so a two-clause no-op is spoken. |
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

**Existing:** `tests/test_speech_path.sh` (timing: first speech well before block completion),
`tests/test_speech_dup.sh` (a shrinking log; a reply behind a thinking block),
`tests/test_wake_filler.sh` (measured from the speaker side), `tests/test_silent_wake.sh`.

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
