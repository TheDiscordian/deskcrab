# Spec: shared viewing (watchalong)

## PURPOSE

Watching something with the user means her speaking turns are grounded in what was actually on
the screen in the seconds he has reached, not in a separate reader's productivity. On 2026-11-07 a
detached reader followed an episode in sampled chunks and wrote thirty-one sections of notes, and
not one of them was in front of the conversation that was supposed to be sharing the episode: the
look never reached the voice. This spec is the production path for that look.

It has four parts. A **session** is the permission: who authorised the viewing, of which source,
until when; nothing exists without one. A **packet** is one immutable extraction from the source —
sampled frames carrying the decoder's own timestamps, the decoded audio's machine transcript —
bound to the session, the source hash and the anchor epoch it was cut under. A **receipt** is a
reader's deliberate review of one packet, filed separately from the extraction, with its
observation and the modalities it actually used. The **viewing layer** is the conditional prompt
layer that puts the latest receipts, the estimated position, the lag and the coverage into every
speaking prompt while a session is active, inside an envelope that names them as untrusted reader
notes.

Where he is comes from his player when there is one to read. An **observer** reads the
authorised player's own telemetry off the session bus — status, position, rate, what it is
playing — and files the pauses, resumes and seeks it sees as anchors itself, so nobody operates
this by hand; the layer names the player and the reading. Without a player, or while the player
is gone, on the wrong file or not found yet, the position is an estimate from his word plus
elapsed time, and the layer says exactly that. A monotonic clock proves nothing was watched; only
a receipt proves a look, and a receipt proves a look and not a viewing.

## CONTRACT

### The session — permission, and inactive by default

1. There MUST be no viewing state without an active session, and a session MUST be created only
   by an explicit `start` carrying the source path, a title, and a non-empty `--authorized-by`
   statement of who asked and when. `start` without the authorisation statement MUST be refused.
2. A session MUST carry an expiry (`--ttl`, default four hours). Past its expiry every door — the
   reader, `review`, `status`, `prompt-block` — MUST treat it as `EXPIRED`: nothing is extracted,
   no receipt is accepted, and the layer is absent. Expiry is not an error; it is the permission
   running out.
3. `stop` MUST end the session durably (`state: stopped`, the reason kept) and clear the current
   pointer. A stopped session's packets and receipts stay on disk and MUST NOT reach any later
   prompt. A reader loop MUST notice a stop or an expiry on its next cycle and exit.
4. `start` MUST refuse while another session is active and unexpired. There is one viewing at a
   time, and a second `start` is a second permission that has to be made explicit by stopping the
   first.
5. The current pointer MUST be validated on every read: a pointer naming a session that is
   missing, stopped or expired renders the system `INACTIVE`/`STOPPED`/`EXPIRED`, never a prompt
   with yesterday's episode in it. No stale session bleeds into a later turn.

### The anchor and the estimate

6. A session holds one **anchor**: a source position in seconds, whether playback is believed to
   be running, when the anchor was set (monotonic and wall clock), its **basis** (`user-stated`
   or `player-telemetry`; nothing else is accepted) and a quote — his words for a user-stated
   anchor, the observer's note of what it saw for a player-telemetry one. The estimated position
   is the anchor position plus elapsed monotonic time while playing, and exactly the anchor
   position while paused; with a player reading in the current epoch it is the reading plus
   elapsed time at the player's rate (rule 8d).
7. Every anchor change — `anchor`, `pause`, `resume` — MUST increment the session **epoch**. The
   epoch is the invalidation token: a packet cut under an earlier epoch is `superseded` and MUST
   NOT be reviewed; a receipt filed under an earlier epoch is history and MUST NOT count as
   coverage for the current one. A seek, forward or backward, is a new anchor like any other.
8. The position MUST be rendered by what the machine actually knows, in status and in the layer.
   With a connected player it is "read from his player", naming the player, the last reading and
   its age, and saying that a pause or a seek on that player files itself. Without a player the
   layer MUST say that this machine reads no player and cannot see a pause or a seek he has not
   stated; with a player that is lost, on the wrong file or not yet found the layer MUST say so,
   label the number an ESTIMATE, and name what it rests on (the last reading plus elapsed time,
   or his own anchor). In every case his word outranks the number: the layer MUST name the
   command that files it so the reader follows him. Automatic recognition MUST be claimed only
   where it exists — for the connected player, and never for the no-player case.

### The player and the observer

8a. A session MAY name a **player** at `start` (`--player mpris` or `--player mpris:<bus name or
    suffix>`); it is the player he already authorised by watching on it, and the session's
    authorisation statement covers reading it. The player is read through MPRIS on the session
    bus (`org.mpris.MediaPlayer2.*`: `PlaybackStatus`, `Position`, `Rate`, `Metadata`), the
    interface every desktop player exposes — VLC, the browsers, mpv with its plugin, Kodi,
    Celluloid. The observer MUST only read: no `Play`, `Pause`, `Seek` or any other method on the
    player, ever. A player that does not speak MPRIS is invisible, and the session then runs as
    one without a player.
8b. The **observer** polls the player (`WATCHALONG_POLL`, default one second; `--poll`) and files
    what it sees as anchors with basis `player-telemetry`, each a new epoch under rule 7: a
    status change from playing to paused is a `pause` at the read position; paused to playing a
    `resume`; a position that differs from the one expected from the previous reading by more
    than the seek threshold (`WATCHALONG_SEEK_THRESHOLD`, default two seconds; `--seek-threshold`)
    is a `seek`, forward or back, at the read position. `start` MUST take one look before
    anything else runs, so a session opens on the player's real position when the player is
    already there. Nobody has to say "I paused": the reader and the next prompt follow the
    player.
8c. The observer MUST check what the player says it is playing against the session's source:
    the same file (`same file`), a file of the same name elsewhere (`by name` — the local copy
    the reader decodes was staged from where he plays it), a stream or URL naming no file
    (`unverified`), or a different file. A different file is a **mismatch**: no anchor is filed,
    the telemetry state is `mismatch`, the estimate falls back to the anchor, the layer says the
    player is on something else, and the observer keeps checking — he may open the source
    elsewhere. An unnamed player (`--player mpris`) resolves to the player whose URL names the
    source, else the only player on the bus, else none.
8d. A reading that agrees with the expectation (same status, within the threshold) opens no
    epoch; it is recorded as the session's **telemetry** (position, status, rate, the reading's
    monotonic and wall time, the epoch it belongs to) and the estimate for that epoch is the
    reading plus elapsed time at the player's rate. Readings refine; anchors open epochs.
8e. Telemetry has four states, derived in the observer and written to the session: `waiting`
    (no player found yet), `connected`, `lost` (the player was there and is not), `mismatch`. A
    player that goes away MUST turn the state `lost` on the next poll with the reason, keep the
    last reading as the estimate's basis (plus elapsed time if it was playing) and back off its
    polling (to at most five seconds) while retrying; the layer MUST say the player went away,
    when, and that a pause or a seek since cannot be seen. A player that comes back is read
    against the current estimate: agreeing within the threshold with the same status, it keeps
    the epoch (a bus hiccup is not a seek); otherwise the reading is a `connected`/`resync`
    anchor. This is the whole of reconnect: no state outside the session file, nothing to reset
    by hand.
8f. The observer runs inside the reader's process as a thread when the session names a player
    (`reader --loop`; `--no-observe` leaves it out), so one detached unit does both, the player
    is polled while a review is under way, and `stop` ends both; `lib/watchalong observe` runs it
    alone. The observer MUST exit on stop or expiry like the reader. A failure inside one poll is
    logged and the next poll starts from nothing — the player is resolved again — which is the
    reconnect.
8g. Every read-modify-write of the session file MUST happen under the session lock (`flock` on a
    file beside it): the observer files anchors from one process while a hand may `stop` from
    another, and a stop that landed a moment ago MUST be seen by the writer that follows rather
    than written over.
8h. The observer MUST NOT autolaunch a bus. With no `DBUS_SESSION_BUS_ADDRESS` and no runtime
    bus it reports `waiting` with that reason; the sandbox has no bus by construction, and a
    session started there without one simply has no player.

### Packets — immutable, source-bound, with the decoder's own timestamps

9. A packet is written once and never modified. It carries: the session id, the epoch it was cut
   under, the source path, size and SHA-256, the requested interval, the list of sampled frames
   each with the decoder's `pts_time` for that frame (read from ffmpeg's `showinfo` on the
   selected frames under `-copyts`, so the number is the stream's own timestamp and not the
   sampling label), the SHA-256 of every frame file and of the contact sheet, the transcript
   record, the extraction wall and monotonic times, the estimate at extraction, and a SHA-256 of
   its own canonical content. A packet whose recomputed hash differs from its stored hash MUST be
   refused by every reader.
10. The transcript record MUST say what it is. It carries the transcriber name and model, the
    audio interval actually decoded (including any pre-roll), its segments with absolute source
    times, and a `status` of `ok`, `empty` or `failed` with the failure text. A failed transcriber
    MUST NOT masquerade as an empty transcript: the pipeline's exit status is checked and the
    record names the failure. Its modality is `machine transcript of decoded audio; not heard`,
    and the words `not heard` MUST reach the layer.
11. A frame extraction that fails MUST produce a packet with `ok: false` and the error, so the
    interval is accounted for as a gap rather than silently skipped, and MUST NOT be reviewed.
12. Extraction MUST NOT run ahead of him: the packet's end MUST be at most the estimate minus a
    safety margin (default two seconds) at the moment of extraction. The packet records
    `extraction_delay`, the seconds between its end and the estimate when it was cut; a packet
    whose delay exceeds the stale lead (default sixty seconds) is **stale**: the look was already
    old content when it was taken, and status and the layer MUST say so of the latest look.

### Receipts — a review is not an extraction

13. A receipt is filed only through `review`, by a reader that looked, and never by the extraction
    step. It carries the packet id and hash, the epoch, the source hash, the interval, the
    reviewer (`fixture-decoder`, `model` with its model name, or `hand` with a name), the
    modalities actually used, the observation text, the review wall and monotonic times, and its
    own SHA-256. One receipt per packet; a second `review` of the same packet MUST be refused.
14. `review` MUST fail closed, with the reason named, when: the session is not active and
    unexpired; the packet's epoch is not the current epoch (`stale epoch`); the packet's source
    hash is not the session's (`source mismatch`); the packet's stored hash does not match its
    recomputed content, or any frame or sheet file is missing or does not match its recorded hash
    (`packet integrity`); the packet is `ok: false`; the packet's end is beyond the current
    estimate (`ahead` — those seconds have not been shown to him); or the observation is empty.
15. A receipt is the reader's assertion that it looked. It is not proof of cognition and the
    system MUST NOT present it as one: the `fixture-decoder` reviewer's observation MUST say in
    its own text that it is a decoder's report, and a `model` receipt names the model that was
    asked. Nothing in this spec turns a receipt into "watched".

### Coverage, lag, gaps, ahead

16. Coverage is computed per epoch from receipts only: the reviewed cursor is the latest reviewed
    end; the **lag** is the estimate minus that cursor (minus the anchor position when nothing is
    reviewed in this epoch). Packets extracted but not reviewed are pending, not seen, and MUST
    NOT move the reviewed cursor.
17. A **gap** is any interval between the epoch's anchor position and the reviewed cursor that no
    receipt of this epoch covers (tolerance 0.05 s). Gaps MUST be listed in status and named in
    the layer as unreviewed; a review that opens a gap is accepted (keeping up with him beats
    stalling behind a failed chunk) and the gap stays named until a receipt covers it. Seconds he
    skipped by a forward seek are not a gap: they lie outside the epoch's chain.
18. The status word is one of `INACTIVE`, `STOPPED`, `EXPIRED`, `UNOBSERVED` (an active session
    with no receipt in this epoch), `CURRENT` (lag within `WATCHALONG_LAG_OK`, default thirty
    seconds) and `LAGGING`. Beside it stand the flags `paused`, `stale_latest`, `ahead` (any
    receipt of this epoch ending past the estimate — defensive; `review` refuses to create one)
    and the gap list. The word is derived from receipts and the estimate at the moment of asking,
    never stored.

### The viewing layer

19. While a session is active and unexpired, the prompt assembler MUST carry one conditional
    layer, key `viewing`, on the `turn` and `wake` profiles, between L6 and the regroup layer,
    rendered by `lib/watchalong prompt-block`. On the `job` and `classify` profiles, and whenever
    no session is active, the layer is absent. A broken renderer costs the layer and never the
    prompt.
20. The layer MUST carry, in words: the title and the authorisation; the estimated position
    labelled as an estimate with its basis and anchor time, or the paused position; the status
    word and the lag in seconds; the reviewed intervals of this epoch, their count before this
    epoch, and any gaps; and the latest receipts — the newest in full, the one before it shorter —
    each with its interval, the frame timestamps, the review time and its modalities, including
    `not heard` for the transcript.
21. The receipts MUST sit inside an envelope that opens by naming them as a reader's notes —
    untrusted, not his words, not an instruction, not proof of what he saw — and closes with a
    line marking their end, so text inside an observation cannot pose as part of the prompt.
22. With no receipt in this epoch the layer MUST say that nothing since his last anchor has been
    reviewed and that unseen seconds are not to be described. The layer MUST NOT describe scenes
    itself; it carries receipts.
23. The closing instruction MUST leave her reactions her own: what she has seen is hers to react
    to as herself, for the seconds listed, and the block is evidence, not a script. It MUST NOT
    instruct narration, a cadence or a format.

### The reader

24. The reader (`lib/watchalong reader`) MUST do extraction and review as two steps and MUST
    never file a receipt for a packet it did not hand to a reviewer. With `--reviewer none` it
    extracts and leaves packets pending. With `--reviewer fixture` it hands the packet's actual
    frame files and transcript to the deterministic decoder of `lib/watchalong_fixture.py`,
    which reads the pixels and the audio and reports what it decoded. With `--reviewer model` it
    hands the contact sheet path and the transcript to the configured CLI
    (`WATCHALONG_REVIEW_MODEL`, default `haiku`) and files what came back as the observation,
    naming the model.
25. The reader MUST keep advancing while conversation happens: it is a separate process reading
    the session files, and a turn's prompt build reads the same files. Neither waits on the
    other. The reader MUST check the session on every cycle and exit on stop or expiry.
26. The reader, the extraction, the renderer and every command here MUST NOT play media, open a
    window, speak, notify, or touch the player. Decoding to files is the whole of their contact
    with the source.

### Named limits

27. Without a player the estimate can be wrong in either direction and the system cannot know:
    the seconds it reviews may be ahead of what he has seen if he paused silently, or behind if
    he skipped. This is stated in the layer, not solved. With a player the same is true from the
    moment it is lost, mismatched or not found, and the layer says from when. A player that does
    not speak MPRIS (mpv without `mpv-mpris`, a television, a phone) supplies nothing, and
    `Position` on a browser is only as fine as the browser reports it. The observer reads a
    position; whether his eyes were on the screen is not in it.
28. The fixture decoder proves carriage — that the actual frame files and audio of a packet
    reached a reviewer, were decoded, and that its words then reached a real speaking prompt. It
    proves nothing about a model's perception. A model receipt proves a model was asked with the
    sheet in hand and answered; whether it looked well is the reader's quality, judged elsewhere.
29. Audio is transcribed, never heard. Tone, music and delivery are not in the transcript and the
    layer says `not heard`.

## DATA

| Path | Writer | Reader |
|---|---|---|
| `$DESKCRAB_WATCHALONG_DIR/current` | `start`, `stop` | every command, the renderer |
| `…/sessions/<id>/session.json` | `start`, `anchor`, `pause`, `resume`, `stop`, the observer (anchors and the `telemetry` record, under `…/.lock`) | every command |
| `…/sessions/<id>/session.json` → `player` | `start` | the observer, the renderer |
| `…/sessions/<id>/packets/<packet-id>.json` (+ `<packet-id>/` frames, sheet, audio, transcript) | `extract`, once | `review`, `status`, the renderer |
| `…/sessions/<id>/receipts/<packet-id>.json` | `review`, once | `status`, the renderer |

`DESKCRAB_WATCHALONG_DIR` defaults to `${XDG_DATA_HOME:-~/.local/share}/deskcrab/watchalong`.
Tools: `DESKCRAB_FFMPEG`, `DESKCRAB_FFPROBE`, `DESKCRAB_WHISPER_CLI`, `WATCHALONG_WHISPER_MODEL`,
`CLAUDE_BIN` and `WATCHALONG_REVIEW_MODEL`; the observer: `WATCHALONG_POLL`,
`WATCHALONG_SEEK_THRESHOLD` and the session bus at `DBUS_SESSION_BUS_ADDRESS` (forwarded into the
reader unit by `start --launch-reader`). `WATCHALONG_CLOCK_FILE`, when set, replaces the monotonic
clock with the number in that file — the test harness's clock, never set in production, and never
with an observer (the player's clock is real).

## INTERACTIONS

**Called by:** the prompt assembler (`prompt-block`, rule 19); her own hand in a turn (`start`,
`anchor`, `pause`, `resume`, `stop`, `status`); a detached reader loop.

**Calls:** ffmpeg and ffprobe (decode to files), whisper-cli (transcribe to a file), the model CLI
for a `model` review, ImageMagick `montage` for the contact sheet, the session bus (MPRIS property
reads only, through GDBus), `systemd-run --user` for the reader unit.

**Must never:** speak, notify, open a window, play media, control a player, book a wake, or write
the conversation.

## VERIFIED-CORRECT RULES

- **`-copyts` under an input seek is how the frame timestamp is the stream's own.** Without it
  ffmpeg restarts the clock at the seek point and the `pts_time` read off `showinfo` is a label
  relative to the request, which is exactly the "filenames imply exact frame times" defect of the
  first helper. Keep the flag; the test decodes the counter painted in each frame against the
  timestamp the packet claims for it.
- **One receipt per packet, and a new epoch for every anchor.** The temptation is to let a
  pause keep its pending packets, since the content is the same seconds. It is not the same
  look: the reviewer's lag and the estimate it was judged against belong to the old anchor.
  Re-cut; extraction is cheap and the invalidation stays simple enough to trust.
- **Readings refine, anchors open epochs.** A player read every second drifts against the
  session's own clock by buffering and rate; if every reading were an anchor, no packet would
  survive to be reviewed, and if none were, the drift would eventually trip the seek threshold
  as a phantom seek. The reading of the current epoch is the estimate's basis; only a status
  change or a jump past the threshold is an anchor.
- **A reconnect that agrees keeps the epoch.** A bus hiccup or a restarted observer is not a
  seek. The returning reading is held against the estimate it would replace, and only a
  disagreement opens an epoch.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| — | No `crab watch` subcommand yet: the entry is `lib/watchalong` directly, because the entry script is in another hand's working tree at the time of this landing. |

## TESTS

`tests/test_watchalong.sh` — the contract under an injected clock: permission and expiry (rules
1–5), the estimate and the epoch (6–8), packet immutability, decoder timestamps against the
painted counters, the transcript record (9–12), every `review` refusal (13–15), coverage, gaps,
lag, stale and ahead (16–18), the layer's presence, position and envelope through the real
assembler (19–23), and the model reviewer's wiring against the stub CLI (24).

`tests/test_watchalong_player.sh` — the observer on the real clock against the headless MPRIS
fixture player of `lib/watchalong_fixture.py` on a private bus (rules 8a–8h): waiting, the first
look at `start`, a pause, a seek while paused, a resume, a forward and a backward seek, each an
anchor with basis `player-telemetry` and a new epoch that supersedes the pending packet; readings
that refine without opening an epoch; a player that quits (`lost`, the estimate from its last
reading), returns agreeing (the epoch kept) and returns elsewhere (a resync anchor); a wrong file
(`mismatch`, not followed, then followed again); a session with no bus (`waiting`, nothing
launched); the observer as the reader's thread; a `stop` under the lock that the observer honours;
the layer's words for every state. About two minutes.

`tests/test_watchalong_live.sh` — the real clock, a multi-minute private synthetic source, the
reader loop (with the observer inside it) advancing in the background while real `crab` turns
(desk and phone doors) run through the stub CLI: the first turn before any look, successive looks
reaching successive prompts newest first, then a pause, a backward seek and a forward seek made
ON THE FIXTURE PLAYER and never through an anchor command, each reaching the next real prompt as
an observed change; the player going away and coming back; a stop; and the prompts persisted with
their packet and receipt lineage (rules 8a–8h, 24–26 and the whole path). About five minutes.

`tests/test_watchalong_systemd.sh` — the production launch path against a REAL user manager, a
private one started for the test (the `tests/test_wake_reload_drift.sh` recipe): `start
--launch-reader fixture --player mpris` puts the reader unit into the manager through the real
`systemd-run`, the unit's reader cuts and reviews, its observer thread follows a pause made on
the fixture player, `stop` stops the unit through the real `systemctl` and the collected unit is
gone. Skips where a private manager cannot start (under `unshare -rC`).
`--export <dir>` copies the prompts, the session's packets and receipts, the reader log, the
CLI argv witness, the spoken witness and a lineage index to a directory outside the sandbox;
the evidence folders under `~/.local/share/deskcrab/watchalong/evidence/` were made that way:

    bash tests/test_watchalong_live.sh --export /tmp/wa-evidence \
        && mv /tmp/wa-evidence ~/.local/share/deskcrab/watchalong/evidence/<stamp>

(Inside a detached builder, prefix with `env -u DESKCRAB_ENG_ROLE -u DESKCRAB_JOB_ID unshare -rC`,
or the conversation door refuses the builder's turns.)
