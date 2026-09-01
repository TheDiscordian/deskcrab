# Spec: face

## PURPOSE

One recognisable face, present while the user and the assistant talk, play
chess, and share the game — and able to move because *she* moved it. The
system is four things: an authored asset family over one stable identity
plate; a small local face-state broker every surface reads; a persistent
conversation portrait window; and mouth cues derived from the speech that is
actually playing. Presence over spectacle: the portrait stays secondary to
the conversation, board, or game, rewards a glance, and never demands one.

The founding idea was **expression is authored, never inferred** — a
classifier handed the delivered transcript must not be able to reconstruct
the expression timeline. On 2026-08-30 the user deliberately superseded the
blanket ban: he asked for a face that is larger, alive on its own, and never
requires a conscious face command per turn. What replaces the ban is not a
free-for-all but a ranked automatic tier (rules 37-45): a deterministic
presence map, per-sentence acting over the words she herself wrote, and a
slow standing mood inferred out of band from the conversation she is party
to. Everything automatic is bounded, inspectable, disableable, stale-proof,
and stands BELOW her explicit hand and the event allowlist. Activity still
comes only from trustworthy runtime facts, and no surface ever infers
anything page-side.

## CONTRACT

### The asset family

1. All generative image work and artistic image editing for the family MUST
   be done by the designated generative image tool, from the approved
   portrait studies as references. Deterministic tools (masks, registration,
   atlases, compositing, scaling, diffs, hashes) do everything after.
2. The resting plate is the identity. Every expression frame MUST carry the
   plate's exact pixels outside its declared facial masks — enforced
   mechanically by compositing, not promised by a prompt — and the
   per-variant QA record MUST show zero changed pixels outside the masks.
3. Face state is layered, never flattened into one mood: presence/activity;
   the expression record with its source; the standing mood baseline (rule
   41); transient speech articulation; and the recovery condition chosen
   when each layer was set.
4. The authored expression family is `attentive`, `caught`, `pleased`,
   `annoyed`, `focused`, `tired`, `startled`. `resting` is the absence of an
   expression record, and the generic default is always `resting`, never a
   guessed mood. `caught` requires her explicit selection or a rule-17
   event; the rest may also be raised briefly by the automatic tier under
   rules 37-45's bounds.
5. No whole-portrait dissolve. A cross-fade is permitted only between
   plate-registered frames whose pixels agree outside the declared masks, so
   the visible motion is local facial change. The 2026-08-30 transition test
   is the reason: two separately regenerated portraits dissolved into a
   double exposure.
6. The motion language is quiet but alive: short expression arrivals with
   easing, and (superseding the 2026-08-30 sway line and its no-breathing
   clause, at the user's 2026-08-31 request) the grounded idle of rules
   51-55 — weight, breathing, and damped secondary motion in her ringlets
   and outfit ornaments. No pulsing borders and no animated-GIF runtime.
   Blinks remain out of this release. `prefers-reduced-motion` (and the
   desktop animations setting) MUST remove all idle and secondary motion
   and yield direct state swaps.
7. Applications learn stable asset ids from a versioned manifest, never
   dated filenames. The manifest carries version, revision derived from
   asset hashes, dimensions, focal point, masks, expression and viseme
   availability, transition durations, and reduced-motion fallback values.
8. Canonical artwork stays in the portrait drawer; applications receive
   fixed local routes and never absolute filesystem paths. Face assets are
   served `no-store`, so an approved replacement lands without a rebuild.
9. The mouth: every expression's mouth-region changes MUST stay inside the
   manifest's viseme patch rect, so a mouth patch painted at that rect over
   any frame lands on a border of stable plate skin.

### Delivery and failure

10. One missing overlay falls back to the nearest stable state (`resting`);
    all art missing removes the portrait cleanly while captions and the
    primary activity keep working.
11. Broken-image chrome is never shown, and a broken layer is never left
    above a good one — a portrait that cannot load leaves the layout.
12. An asset route resolves only ids present in the manifest, and the
    resolved file must still live inside the portrait drawer. No route ever
    accepts a caller-supplied filename or path.

### The broker and her hand

13. `crab face` is her expressive hand: fast, local, callable from an
    ordinary live turn, idempotent, and it MUST report whether the state was
    accepted. Verbs: an expression name (optionally `--for <seconds>`),
    `rest`, `pulse <expr> [seconds]`, `activity`, `event`, `speak-stop`,
    `status`, `watch`. Unknown words are refused, not guessed at.
14. (Amended 2026-08-30, at the user's explicit request.) Automatic
    expression exists, but ONLY through the broker's ranked automatic tier
    (rules 37-45). Expression MUST NOT be derived from chess evaluation,
    hit points, face recognition, or anything about the user; no browser
    surface may run its own inference; and every automatic path is
    disableable, after which the pre-amendment behaviour is exactly what
    remains.
15. The presence/activity layer comes only from trustworthy runtime facts:
    push-to-talk capture (`listening`), a turn or autonomous wake forming a
    reply (`considering`), validated live job records, scheduled speech clips
    (`speaking`), a chess think (`chess`), a fresh logged-in OpenRSC bridge,
    and their absence (`sleeping`, after the settling delay). The spectator's
    pause/resume stays the page's own local activity truth.
16. Expression sources are ranked: `explicit` > `event` > `auto`. A new
    record lands only when its rank is at least the standing record's, so
    her explicit choice outranks everything until she releases it or its
    chosen lifetime ends, and a confirmed event outranks anything
    automatic. A bare explicit choice has a bounded default lifetime
    (`DESKCRAB_FACE_EXPLICIT_SECONDS`, default 120 s); `--for N` chooses a
    different lifetime, and only an explicit `--hold` makes it indefinite.
    A new choice at equal-or-higher rank supersedes the old one.
17. The event allowlist maps a confirmed game win to `pleased`, a confirmed
    failed action to `annoyed`, an incoming player message or NPC quest line
    to `attentive`, and the start of combat to `focused`, nothing else. A
    routine failed action recovers after eight seconds by default rather than
    holding an agitated pose for the general event lifetime. It is inspectable
    (`crab face status` prints it), disableable (`DESKCRAB_FACE_EVENTS`),
    and an event-sourced expression always carries a bounded lifetime.
18. Activity changes never erase an expression record. A record ends only
    by her explicit recovery, a newer choice at equal-or-higher rank, or
    the lifetime chosen when it was set. `release` removes only the standing
    expression and reveals the automatic layers underneath. Her explicit
    `rest` clears the standing mood too — an automatic baseline repainting
    the face seconds after she asked for composure would make her hand
    weaker than the machinery under it.
19. The broker is one small local process on one unix socket (mode 0600),
    one per state prefix. It retains state across a viewer being covered,
    moved, or reloaded (a snapshot file under the state prefix), streams
    changes to `watch` connections, answers a bounded long-poll `wait`, and
    `crab face status` shows activity, expression, clips, cue position, and
    connected surfaces. A second broker against a live socket exits quietly.

### Speech articulation

20. The viseme family is `rest`, `slight`, `open`, `wide`, `round`, `teeth`;
    `rest` is the current expression's own mouth. The cue track is a pure
    function of the synthesiser's phoneme record and the clip's measured
    duration, so a fixture can hold the whole track still.
21. Mouth cues derive from the actual outgoing speech path: the
    synthesiser's own per-clip record of the audio it produced — never from
    the written reply, and never from a page timer guessing. The desk
    streamer reads that record directly from Piper's debug drain. Phone and
    phone-routed wake synthesis retain the same phoneme records, measured
    duration, and derived cue track in a private sidecar beside the generated
    Opus file; the browser receives only an opaque cue id. No audio means no
    lip movement, even if text claims she is speaking.
22. Cue time zero is the clip's playback start. With the long-lived desk
    synthesiser pipe, playback start is modelled: a clip begins either when
    the audio scheduled before it drains, or one pipe-and-device lead
    (`DESKCRAB_FACE_AUDIO_LEAD`, documented beside the manifest) after its
    synthesis lands. For phone audio, the media element's real `playing`
    report is time zero: the server looks up its own retained cue document
    by opaque id and publishes that clip to the broker then, never when the
    file was generated or merely requested. Sentence gaps return toward the
    expression's resting mouth without resetting chosen eyes and brows. The
    measured desk error is recorded with the review sheets, and the
    conversation window is authoritative for lip sync. The chess table, the
    spectator, and the standalone viewer may render the broker's cue tracks
    in full, read-only, correcting for server clock skew from the state
    document's own `now`; a mirrored mouth is still only ever the real clip
    schedule, never a page timer guessing from text.
23. Stopping speech, playback failure, interruption, or `shutup` closes the
    mouth immediately and clears the affected cues: the streamer's own drain
    and term paths and `shutup_now` say `speak-stop`; a phone clip's terminal
    playback report removes that clip by id without erasing another voice's
    track. Every scheduled clip carries a finite duration, so even a lost
    terminal report cannot animate past the clip's end.
24. A late-joining viewer lands at the current cue position of the clip now
    playing; old mouth motion is never replayed. Exactly one opaque patch is
    painted: on each cue its source changes at the outgoing contour's extent
    and that single contour eases geometrically to the incoming extent about
    the manifest's lip anchor (rule 55); on ordinary close it contracts to
    rest before the expression plate resumes. Old and new contours are never
    opacity-crossfaded. An explicit stop, interruption, or playback failure
    still closes the mouth at once.

### The conversation portrait window

25. The window is ordinary: her application identity and icon, placeable,
    coverable, minimizable, closable, never always-on-top, never a
    notification, wallpaper, tray glyph, or overlay above the games. Its
    size is remembered; its position belongs to the compositor (Wayland
    offers a client no say), and that limit is stated, not papered over.
26. It shows the portrait at its authored size with a terse activity
    caption; joins the broker's current state on open; close and reopen
    reset nothing and never disturb speech or the broker; it launches
    detached so no spoken request ever waits on a GUI start; and it does not
    replace or disturb the display-channel window.
27. It pauses per-frame animation while unmapped and honours the desktop
    animations setting as its reduced-motion signal. The root idle motion
    moves the complete composited figure, including the mouth patch, as one
    unit; motion regions (rule 52) add their lag inside that same stage, so
    the mouth never detaches from the face.

### Never a dependency

28. The face is company, not plumbing the voice depends on. Every caller
    treats the broker as best-effort: a dead broker costs one refused local
    connect; a page that loses it freezes on the last safe still and
    reconnects with bounded backoff, without spinning, flashing, or blocking
    use. `FACE_ENABLED` (default off) gates only the automatic emitters —
    the turn pipeline, the streamer's cue plumbing — while the explicit hand
    and the window work regardless, as their invocation is its own opt-in.
29. With no face socket in its environment, the speech streamer runs exactly
    as it did before the face existed — same processes, same pipeline, same
    receipts. Off is the prior behaviour.
30. Armed, the only speech-path change is the synthesiser's debug log and
    its drain: a cue failure of any kind never delays, reorders, drops, or
    rewrites a word. The standing rule of
    [speech-output.md](speech-output.md) outranks every line of this spec.

### The chess table

31. `/thinking` remains the table's activity truth: attentive while called
    or genuinely considering, rest after the move lands, and the existing
    text remains the exact status account. The broker mirror is read-only,
    adds explicit expression and speaking presence only, and its absence
    degrades to the local activity state. Expression is never derived from
    evaluation.
32. The face stays subordinate: smaller than the board on the desktop card,
    a compact head-and-caption row on narrow phones, and it never squeezes
    the board, clocks, connection controls, chat, or move controls.

### The spectator

33. Portrait and face routes live inside the same spectator key boundary as
    the frame and state routes; the key's scope widens for nothing, and the
    spectator gains no control capability of any kind.
34. Pause makes the activity attentive/paused and Resume returns it without
    restarting frame delivery; the caption uses only allowlisted facts
    already served to the HUD.
35. The mirror is read-only; the portrait never steers play.

### Tests

36. Every test pins `DESKCRAB_PORTRAIT_DIR`, `DESKCRAB_FACE_SOCKET`, and the
    face state file under its sandbox; no test reads the live drawer or
    touches a live broker.

### The automatic tier (2026-08-30 amendment)

The user asked for a face that moves on its own — size, activity, and
emotion — with no conscious face command per turn and no cost to speech.
These rules define the ONLY automatic paths, all below her hand.

37. The critical-path guarantee outranks everything here: no automatic
    classification is ever awaited before text streams, speech begins, or a
    turn returns. The mood updater is dispatched detached after delivery;
    per-sentence acting rides the streamer's existing fire-and-forget side
    threads; the deterministic activity map is a broker-side lookup. A
    failure anywhere in the tier costs an expression, never a word and
    never a millisecond of speech.
38. Turn tokens. The turn machinery registers a fresh token with the broker
    (`activity` carrying `turn`) when a reply starts forming. Every
    automatic write (`auto` expression, `mood`) carries the token of the
    turn it was computed for, and the broker refuses a stale one: a
    classification from a finished turn never repaints the current one.
    A write with no token competes with nobody and stands on its own.
39. The deterministic activity map: `listening`→`attentive`,
    `considering`→`focused`, `chess`→`focused`, from runtime facts already
    in the presence layer, resolved in the broker's snapshot with no model
    call and no record created. It shows only when nothing outranks it.
    Configurable and disableable via `DESKCRAB_FACE_ACTIVITY_EXPRESSIONS`.
    No remote request may be spent on a state this map already covers;
    inference is reserved for emotional expression.
40. Per-sentence acting: as the streamer schedules each REAL clip, a fixed,
    public, inspectable table (`face_state.SENTENCE_CUES`, printed by
    `crab face status`) is matched against the sentence SHE wrote; a match
    files an `auto` expression timed to the clip's modelled playback start
    and bounded by clip length plus `DESKCRAB_FACE_CUE_LINGER`. Immediate
    emotion — surprise first — lands WITH its sentence and is never
    smoothed into the baseline or delayed by it. Disableable via
    `DESKCRAB_FACE_SENTENCE_CUES=0`. No model runs here.
41. The mood baseline: one standing signal (`pleased`, `annoyed`, `tired`,
    `focused`, `attentive`, or none) the broker holds with a bounded
    lifetime (`DESKCRAB_FACE_MOOD_SECONDS`, default 900 s, refreshed on
    update, decaying to nothing on its own). It gives the face emotional
    continuity between turns and shows only when no expression record
    stands. Every non-neutral mood record also carries a concise reason; a
    concrete subject source such as `RuneScape`, `chess`, `coding work`, or
    `conversation about her face`; the mechanical origin (`desktop exchange`,
    `phone exchange`, or `autonomous wake`); the originating turn reference
    when one exists; and its set and expiry times. The broker snapshot and
    diagnostics expose all of them. The updater mechanism and delivery channel
    are provenance, not the source of a feeling.
42. The mood updater (`lib/face-auto`) runs detached after every completed
    desk or phone exchange and every successful wake, including wake work
    kept silent by its delivery gates. It reads the exchange or wake agenda,
    a bounded conversation tail, the current activity, and the PRIOR mood,
    and asks one classifier-shaped question through `claude_classify` on
    `FACE_AUTO_MODEL` (default `haiku` — the cheapest reliable route this
    codebase already has). A successful wordless wake uses its work trace as
    the completed-work half. Continuity is in the prompt: it moves the
    standing mood, it does not judge one line in isolation. Its answer carries
    the mood word, a brief reason for the movement, and a short concrete source
    naming what the feeling is about. The updater adds the mechanical origin
    and turn reference itself rather than asking the model to invent
    provenance. A non-neutral answer with no useful subject source is
    unparseable and changes nothing. The delimiter may be an actual tab or the literal
    token `<TAB>`: classifier routes sometimes preserve the format marker
    verbatim, and that mechanically equivalent answer is not a failed mood.
    Gated by
    `FACE_AUTO_EXPRESSION` (and `FACE_ENABLED`); bounded by
    `FACE_AUTO_TIMEOUT`; every failure, refusal, or unparseable answer
    changes nothing and is one line in `${STATE_PREFIX}-face-auto.log`.
42a. A current standing mood MUST appear in the assistant's self-state prompt
    as `How you feel`, followed by its stored reason, concrete subject source,
    mechanical origin, and turn reference. When a retained record predates a
    usable reason or source, its update time, origin, reference, and face-updater
    log path still appear, so she can inspect the concrete originating record.
    Naming only the automatic updater is never a source. This is a read of the
    broker's existing record: it runs no classifier and starts no broker while
    the prompt waits.
43. Resolution order, in the broker's snapshot so every surface agrees:
    explicit/event expression > true-idle `sleeping` > automatic expression
    > mood > activity map > `resting`. Sleep's special position is rule 59:
    her hand and confirmed events still stand, while an old automatic layer
    cannot keep her awake. Failure of emotional automation defaults to
    `resting`; a stale presence observer follows rule 61 and sleeps — never a
    guessed mood, never a permanent hold.
44. Privacy boundary: the mood updater reads only the conversation she is
    already party to, through the same model route and account walk every
    other out-of-band judge uses; nothing new leaves the machine. Browser
    surfaces receive resolved state and never run inference; nothing in the
    tier reads the user's camera, screen, or anything about the user's own
    affect.
45. Off is still the prior behaviour: with `FACE_AUTO_EXPRESSION=0` and
    `DESKCRAB_FACE_SENTENCE_CUES=0` and an empty activity map, the face
    does exactly what the pre-amendment spec said, and with `FACE_ENABLED`
    off the speech path is byte-identical to the face never existing
    (rules 28-30 stand unamended).

### Size (2026-08-30 amendment)

46. Every browser face surface carries an OBVIOUS size control beside the
    portrait — a labelled button cycling `compact` / `medium` / `large` —
    and the choice persists locally (localStorage, one key per surface) so
    it survives reloads. `large` is materially larger (spectator: 48 px
    grew to a 164 px card; chess: 148 px), while the game or board stays
    the page's primary surface (rule 32 stands). The shared renderer
    (`lib/face_card.js`) carries the mechanics for all of them; policy —
    routes, captions, what each size means in pixels — stays on the page.
47. Legibility of the small card is a display treatment, never a repaint:
    manifest `focal` steers `object-position`, a mild CSS
    brightness/contrast lift and a backdrop gradient raise the face out of
    the dark study, and the speaking cue is a steady border shift — no
    pulsing, no bobbing, and `prefers-reduced-motion` still yields direct
    swaps.
48. The conversation portrait window keeps rule 25: it is an ordinary
    window whose free resize is its size control and whose chosen size is
    remembered in `face-window.json`. It inherits the whole automatic tier
    for free because resolution happens in the broker (rule 43).

### The standalone viewer (2026-08-30 amendment)

49. `/face` on the phone server is her portrait alone — the same shared
    renderer, the same broker mirror (`/face/state`, `/face/manifest.json`,
    `/face/asset/<id>`, `/face_card.js`), the same remembered sizing with
    viewer-scale presets — meant to stay open on its own display or
    workspace. It sits behind the app's own auth, gains no control
    capability, and its absence costs nothing.
50. Face state routes on both servers accept `?after=<seq>`: the broker's
    own bounded long-poll holds the answer until state moves, so expression
    changes and clip schedules land when they happen. A server that cannot
    wait answers immediately, and the shared renderer degrades to plain
    polling with bounded backoff either way.

### Presence in motion (2026-08-31 amendment)

The user looked at the standalone viewer and found the 2026-08-30 sway
invisible, and the figure — one flat image rocked around its centre — not
present. He asked for a visibly alive, grounded idle: weight, breathing,
convincing spring-and-damper secondary motion in the ringlets and the
outfit's ornaments, mouth shapes that no longer lurch between sizes, and
named handles the machinery can later pull for reactions such as irritation
or scolding.

51. Grounded idle. The root motion moves the whole composited figure like a
    standing body, not a card: a slow weight sway pivoted at the frame's
    bottom centre, a breathing lift (a small vertical scale about the same
    ground pivot, on an asymmetric inhale/exhale curve), and a slight
    lateral weight shift — perceptible at a glance at the viewer's sizes,
    restrained enough to stay company (amplitudes on the order of a few
    pixels at plate scale, stated in the manifest-adjacent build record).
52. Motion regions. The manifest MAY carry a `motion` section: named
    regions, each with a feathered mask asset registered to the plate, a
    pivot at the region's anatomical attachment, a mode (`pendulum` for
    hanging parts, `bob` for mounted ornaments), spring stiffness and
    damping, and drive gains. Masks are derived deterministically from the
    approved frames (rule 1's deterministic-tools clause — no generative
    step) and live in the drawer as ordinary manifest assets. A region
    renders as a masked copy of the resting plate — rule 2 guarantees those
    pixels are expression-invariant — painted inside the same root motion
    stage as everything else, so the mouth patch never detaches (rule 27).
    A manifest without the section, a surface without animation support, or
    reduced motion yields the still portrait exactly as before.
53. Secondary physics. Each region is a damped spring driven by the root
    motion, so ringlets and ornaments lag the torso, overshoot, and settle;
    mask alpha and pivot placement taper the amplitude to zero at the
    attachment. Region motion stays local: a region never translates more
    than its mask's feathered margin, so no seam of doubled artwork can
    open.
54. Motion channels. Every surface's renderer exposes the same named,
    bounded expressive channels — `energy`, `agitation`, `droop` — and
    one-shot gestures — `shake` (the scold), `bounce`, `perk`, `nod` —
    ranked like expression itself: an explicit `motion`/`gesture` field in
    the broker state document (reserved for her hand and the automatic
    tier; the broker does not emit it yet) outranks the fixed public
    mapping from the resolved expression (annoyed raises `agitation` and
    fires one `shake`; pleased `bounce`s; startled `perk`s; tired droops),
    which outranks the idle defaults. The mapping reads only rule 43's
    resolved expression — no page-side inference — and channels move motion
    only, never pixels of expression art. `annoyed` keeps only low sustained
    agitation (`0.18` by default): its one-shot `shake` carries the scold, so
    repeated mechanical failures cannot turn the held pose into vibration.
    When an agitated expression resolves to a non-agitated one, every renderer
    ends the agitation driver and its remaining spring impulse immediately;
    calm must not inherit visible trembling while root sway and breath continue.
55. Mouth normalisation. Viseme patches are normalised by the deterministic
    build so every changed region stays within a stated band of the resting
    lip line (the build record carries the measured before/after extents;
    the oversized `open` and `wide` of 2026-08-30 are the reason). The
    manifest carries each viseme's measured `extent` and the family's lip
    `anchor`; renderers use them for rule 24's morph. The build removes the
    resting contour into one deterministic clean-mouth plate before laying
    down a viseme, then centres the changed contour on that anchor: exactly
    one mouth contour may remain in any speaking patch, with no old frown
    exposed underneath. Patch borders remain stable plate skin (rule 9), and
    nothing outside the viseme rect ever changes.
56. OpenRSC reactions. One read-only local observer watches the bridge's
    atomic `state.json` and remembers the last message, skill levels, quest
    statuses, and combat edge it saw. It seeds from an already-running game
    without replaying history. Only confirmed transitions enter rule 17:
    incoming player messages, NPC quest lines, skill/quest completion,
    mechanically explicit failure/success feedback, and combat start. It
    never steers the game, never reads hit points as emotion, and its service
    may be stopped without changing play or the portrait's other layers.
57. Whole-person presence. One local observer aggregates the live session
    registry (desktop turns, phone turns, and autonomous wakes), validated
    running job sidecars, and a fresh logged-in OpenRSC bridge. It replaces one
    broker layer atomically; a finishing hand can never write `resting` over a
    different hand that is still working. Chess, listening, and speech retain
    their immediate runtime edges above the aggregate.
58. Meaningful activity only. Pending timers, status reads, filesystem churn,
    and the observer's own polling never count as activity. A brief gap after
    the final live source settles before sleep, so bookkeeping edges cannot
    make the eyelids twitch. Any new source wakes the face on the next poll.
59. True idle resolves to `sleeping`, with a registered authored frame whose
    eyes are fully closed. Explicit and event expressions remain above sleep;
    sleep is above automatic flourishes, mood, and the ordinary activity map,
    so a stale baseline cannot hold the eyes open through genuine idleness.
60. Sleep motion is grounded: low energy, deep droop, slower breathing, reduced
    sway, and damped ornament/ringlet lag in the same root stage as every other
    state. It is not a card bob or a sleep-symbol effect. Reduced motion yields
    the closed-eye still directly.
61. Stale safety is two-sided. Direct runtime edges expire if their emitter
    disappears; the aggregate heartbeat also expires, failing safe to sleep.
    `crab face status` exposes the resolved activity, aggregate sources, direct
    edge, aggregate edge, and their times.
62. The sleeping frame obeys the family invariant mechanically: generated art
    supplies the closed-eye features, then deterministic compositing restores
    exact resting pixels outside the declared brow, eye, and mouth masks. The
    build record must report zero changes outside those masks.

## DATA

| Path | Owner/Role | Purpose |
|---|---|---|
| `<portrait drawer>/manifest.json` | build script writes; both servers and the window read | the asset contract of rule 7 |
| `<portrait drawer>/living/` | build script | canonical frames and mouth patches |
| `${STATE_PREFIX}-face.sock` | broker binds; every caller connects | rule 19's one socket (`DESKCRAB_FACE_SOCKET`) |
| `${STATE_PREFIX}-face-state.json` | broker | the retained snapshot behind rule 19 |
| `${REMOTE_AUDIO_PREFIX}*.opus.face.json` | phone synthesiser; phone server reads | private, bounded phoneme records, duration, and cue track for rule 21 |
| `$XDG_STATE_HOME/deskcrab/face-window.json` | window | remembered size (rule 25) |
| `DESKCRAB_FACE_AUDIO_LEAD` | streamer | rule 22's documented playback lead |
| `DESKCRAB_FACE_EVENTS` | broker | rule 17's disableable allowlist |
| `DESKCRAB_FACE_ACTIVITY_EXPRESSIONS` | broker | rule 39's deterministic map |
| `DESKCRAB_FACE_SENTENCE_CUES` | broker+streamer | rule 40's on/off switch |
| `DESKCRAB_FACE_CUE_LINGER` | streamer | rule 40's flourish tail |
| `DESKCRAB_FACE_MOOD_SECONDS` | broker | rule 41's mood decay clock |
| `DESKCRAB_FACE_EXPLICIT_SECONDS` | broker | rule 16's default lifetime for a bare manual expression |
| `DESKCRAB_FACE_FAILED_ACTION_SECONDS` | broker | rule 17's short mechanical-failure recovery (default 8 s) |
| `DESKCRAB_FACE_AUTO_SECONDS` | broker | default lifetime of an `auto` record |
| `FACE_AUTO_EXPRESSION`, `FACE_AUTO_MODEL`, `FACE_AUTO_TIMEOUT` | conf, read by common.sh and `lib/face-auto` | rule 42's updater knobs |
| `${STATE_PREFIX}-face-auto.log` | `lib/face-auto` | one line per updater run |
| `${STATE_PREFIX}-face-state.json` | broker writes; prompt state reads through the broker | current mood, reason, source, source reference, and timing |
| localStorage `deskcrab-face-size-{openrsc,chess,viewer}` | each page | rule 46's remembered size |
| manifest `motion` section | drawer build script writes; every renderer reads | rule 52's regions: mask asset, pivot, mode, spring constants, drive gains |
| manifest viseme `extent`/`anchor` | drawer build script | rule 55's morph measurements |
| `<portrait drawer>/motion-build-record.json` | drawer build script | rule 51/55's stated amplitudes and before/after extents |
| `${STATE_PREFIX}-game/state.json` | OpenRSC bridge writes; `face-openrsc` reads | rule 56's confirmed game transitions |
| `${STATE_PREFIX}-face-openrsc.json` | `face-openrsc` | replay-safe cursor for rule 56 |
| `${STATE_PREFIX}-sessions/` | turn/wake registration | live hands read by rule 57's observer |
| `<jobs drawer>/*.json` | job runner | validated live builder facts for rule 57 |
| `<portrait drawer>/sleep-build-record.json` | deterministic asset build | sleeping-frame source, method, and pixel invariant |
| `DESKCRAB_FACE_SLEEP_AFTER` | `face-presence` | settling delay before true-idle sleep (default 20 s) |

## INTERACTIONS

**May call:** the broker calls nothing; `lib/face-broker`, `lib/face-presence`, the streamer's
cue plumbing, the turn pipeline's `face_touch`, `lib/face-auto`, and both
web servers connect to the broker socket; `lib/face-auto` calls
`claude_classify` (and through it the account walk); the window reads the
manifest and drawer directly (it is local company, not a browser).

**May be called by:** `crab face`, `crab face-window`, the desk turn
pipeline (`face_touch`, `fire_face_mood`), `lib/tts-streamer`,
`lib/serve.py`, `lib/chessweb.py`.

**Must never:** run automatic expression outside the ranked tier of rules
37-45, or infer from evaluation, hit points, or anything about the user
(rule 14); block, delay, or gate speech or a turn (rules 28-30, 37);
accept a caller path on any route (rule 12); widen the spectator key's
scope (rule 33); write game controls (rule 35).

## VERIFIED-CORRECT RULES

- The masked-composite invariant (rule 2) is enforced by copying plate
  pixels back over everything outside the declared masks after all
  resampling, and then counted on the saved file — the 2026-08-30 study
  proved a prompt alone cannot hold it.
- The streamer's cue plumbing is fire-and-forget on a side thread with the
  pump untouched; every failure path continues the drain (rule 30).

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| FACE-1 | Playback start is modelled (rule 22), not measured from the device; the lead constant has not been calibrated against live audio hardware. |
| FACE-3 | Wake speech (`speak_once`) bypasses the streamer and schedules no cues and no `speaking` presence. |
| FACE-4 | Opening the window under a focus-follows-new-window compositor may still focus it; no client-side fix exists under Wayland. |
| FACE-6 | Web mouth mirrors assume the square 420×420 family: a future non-square plate would need crop-aware mouth-rect math in `face_card.js`. |

## TESTS

**Existing:** `tests/test_face_presence.sh` (validated all-hand aggregation,
sleep precedence, stale safety, and both renderers' sleeping motion map);
`tests/test_chessweb.sh` (fixed portrait routes, native page
markup, thinking-driven attentive class); `tests/test_openrsc_web.sh`
(spectator-key gating of portrait routes, unknown names refused, pause
expression markup).

**To be written / this branch:** `tests/test_face_broker.sh` — the broker's
layered state, the full precedence ladder (explicit > event > auto > mood >
activity map), turn-token staleness, recovery lifetimes, speak/speak-stop,
the cue track function's fixture, the sentence-cue table, the streamer's
per-sentence acting against a stub synthesiser, and the mood updater's
no-block/stale/failure behaviour against a stub classifier. Both web suites
additionally pin the size control markup, the shared renderer route, and
`?after=` answering with a dead broker; the chess suite further pins the
motion-region mask route, the renderer's motion engine and channels, and
the extent-driven mouth morph (rules 24, 51-55).
