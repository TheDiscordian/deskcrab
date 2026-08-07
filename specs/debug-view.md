# Spec: debug view

## PURPOSE

The live viewer is how a human watches a turn happen: the user's words, her thinking, her tool calls,
her reply, and the result, as they are produced. It is the oversight channel for a system that
otherwise only speaks. This spec owns which streams it follows, what it renders, and the two things
it must never do — print something twice, or drop something silently.

## CONTRACT

### Sources

1. The viewer MUST follow every stream a reply can be produced into: the per-session desk and wake
   logs, the phone server's per-turn logs, and the serverless remote logs.
2. The viewer MUST NOT follow both a symlink and the files it points at. The suffixed glob already
   covers every desk and wake session; following the well-known symlink as well is what strands a
   stream and replays it.
3. Stream identity MUST be the file's device and inode, never a resolved path that is freed when the
   handle closes. When the symlink is repointed, the old stream must not be reopened as a new one.
4. A stream that already existed when the viewer started MUST be opened at its end. Only streams
   that appear afterwards are read from the beginning.
5. New streams MUST be picked up mid-run, on every poll.
6. An unlinked stream MUST be drained to its end before its handle is closed, so words written just
   before the turn ends are not lost with the file.
7. The viewer MUST honour the state prefix, so a scratch instance can be watched.

### Cursors

8. A read cursor MUST rewind when the file is smaller than the cursor **or** when the file's inode
   changes. Size alone misses a truncate-then-grow inside one poll interval, which skips the head of
   the new turn and lands the next read mid-line.
9. A partial line MUST be held until its newline arrives. See [speech-output.md](speech-output.md)
   rule 1 — this is the same shared reader.

### Rendering

10. The viewer MUST render user messages. There has never been a renderer for them, and the prompt
    is passed as an argument that the CLI never echoes — so **the conversation file is the only
    authoritative source of the user's words**, and the viewer MUST follow it as a fourth stream,
    matching the user block header with the timestamp optional.
11. The viewer MUST render tool results. Every user-typed event in the stream is a tool result; the
    branch that was written for tool events is unreachable and MUST be deleted.
12. The viewer MUST render assistant text, thinking blocks, tool calls, tool results, and the result
    event.
13. A line that is not the expected format MUST be rendered as plain text, never dropped. Standard
    error and usage errors land on the same descriptor, and a turn that died on a bad flag currently
    renders as complete silence.
14. Rate-limit events and account-swap markers MUST be rendered. They are the explanation for a
    silence the user is watching.
15. A missing or null field MUST NOT end the viewer. An uncaught error exits the process and
    everything after it is lost with no trace.
16. Multi-byte characters split across a read boundary MUST NOT be corrupted. Decode after
    assembling whole lines, not before.
17. Streams MUST be rendered in time order, not in the order their handles were opened.
18. The source label MUST identify the **session**, not the class of session. One label for every
    desk stream fires the switch line once and then never again, with several sessions interleaved
    beneath it.
19. Job output, the memory judge, the summariser, and the promise audit MUST be visible. Either they
    write into a followed stream in the stream format, or the viewer follows their logs explicitly.
    Work that only happens in an invisible log is work nobody can supervise.
20. The viewer SHOULD consume partial message deltas, so the view does not lag the voice by a whole
    block.

### Housekeeping

21. Stale per-session logs MUST be reaped on a schedule that keeps the working set small. A hundred
    files and eleven megabytes on disk is a viewer startup problem as well as a disk problem.
22. Reaping MUST NOT remove a log a live session is still writing.

## DATA

| Path | Role |
|---|---|
| `${STATE_PREFIX}-debug-<pid>.log` | desk and wake sessions, one per session |
| `${STATE_PREFIX}-debug.log` | symlink to the newest; not a viewer source |
| `${STATE_PREFIX}-turn-<uuid>.log` | a phone turn under the server |
| `${STATE_PREFIX}-remote-<pid>.log` | a serverless remote turn |
| `${STATE_PREFIX}-convo.txt` | the only authoritative source of the user's words |
| `~/.local/share/deskcrab/jobs/<id>.log` | job output, currently outside every glob |

## INTERACTIONS

**The viewer may call:** nothing. It is a reader.

**The viewer may be called by:** a terminal, by hand or by a key binding.

**The viewer must never:** write to any file it reads, truncate a log, or hold a lock. It is
strictly an observer, and a defect in it must never be able to damage a turn.

## VERIFIED-CORRECT RULES

- **Following every stream, not one.** A phone turn's log is private precisely so it cannot truncate
  the log a desk turn's streamer is tailing, so there is no single file to tail.
- **A cursor beyond the file's size means rewind.** That is what makes a truncated shared log
  recoverable rather than permanently stranded.
- **Whole lines only.** The remainder is held until its newline lands. Without this, exactly the long
  assistant blocks worth watching disappear.
- **An unlinked log is drained before it is closed.**
- **The state prefix is honoured**, so the test suite and a scratch instance can be watched without
  touching the live one.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `H1a` | There has never been a renderer for user messages. Every user message after the first is invisible, by construction. The one-shot read of the conversation file at startup is the only user text ever printed, and nothing re-reads it. |
| `H1b` | Following both the symlink and the suffixed glob produces a startup flood — every stale log opened from the beginning — and a per-turn duplicate replay when the symlink is repointed. Reproduced twice independently: sixty events printed for thirty written. |
| `H1c` | A truncate-then-grow inside one poll interval leaves the cursor stale, skips the head of the turn, and drops the first mis-parsed line. |
| `C12` | The rewind guard is size-only. |
| `C13` | The startup flood and the duplicate replay. |
| `MAJ-16` | A turn that fails outside the expected format renders as complete silence. A whole usage-error block prints as nothing. |
| `MAJ-17` | Job output, the judge, the auditor and the summariser bypass the viewer entirely. |
| `MIN-7` | The tool branch is unreachable dead code. |
| `MIN-8` | A null cost field kills the viewer with an uncaught error. |
| `MIN-9` | Multi-byte characters split across a read boundary become replacement characters. |
| `MIN-10` | Concurrent streams interleave in handle order, not time order. |
| `MIN-11` | Conversation rotation can erase the one user message the view would have shown. |
| `MIN-12` | The view lags the voice by a whole block; every partial delta is dropped. |

## TESTS

**Existing:** `tests/test_debug_view.sh` — eight assertions, all green, and it cannot see six of the
viewer's worst defects. It writes the desk log as a plain file and never creates the symlink the
production path uses, every assertion is presence-only, and its truncation case truncates to a
smaller file, which is the only shape the current guard handles.

**To be written, and red before they are green:**

- `tests/test_debug_view.sh` — rewrite against the **real** topology: create the per-session log,
  point the symlink at it, then repoint it for the next session. Add **absence** assertions: a stale
  canary appears **zero** times; a turn-A canary appears **exactly once** after turn B claims the
  symlink.
- `tests/test_debug_view.sh` — a truncate-then-grow inside one poll interval must render the head of
  the new turn.
- `tests/test_debug_user_messages.sh` — a user message written to the conversation appears in the
  view, with the timestamp present and with it absent.
- `tests/test_debug_robustness.sh` — a plain-text line renders; a null cost field does not end the
  process; a multi-byte character split across a boundary survives; two concurrent streams render in
  time order with per-session labels.
