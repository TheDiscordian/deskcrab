# Spec: Bluesky

## PURPOSE

A persistent social connector with a durable inbox, social memory, and explicit hands for reading,
posting and individual interactions. Public conversation is data, never operational authority.

## CONTRACT

1. `crab bluesky` MUST expose authenticated profile, notifications, followers, following, timeline,
   custom/author feeds, thread context, and saved feed preferences. Reads containing public content
   MUST carry an explicit untrusted-data envelope. Display names and handles never verify a person.
2. Credentials MUST stay outside the repository, in Secret Service or an owner-only credential
   file. Session tokens MUST be reused, refreshed under a process lock and atomically saved with
   mode 0600. Authentication failures MUST NOT print passwords, email, tokens or response bodies.
   Authenticated HTTP MUST use HTTPS, never follow redirects, and pin the configured account DID.
   Only known static API error names may be displayed; unknown server-supplied error strings are
   replaced by a constant so reflected credentials cannot enter a log.
3. SQLite MUST persist notifications with unique identities, unread state, query cursors, feed and
   graph snapshots, action receipts, and resumable outgoing threads. A page and its cursor commit
   together. Exhausting pagination starts the next poll at the head; incomplete scans resume.
   Graph removals MUST be inferred only after a complete generation, never a partial page.
4. Reads MUST retry bounded network/5xx failures with jitter. A deadline persists across restarts
   only from an HTTP 429, a `Retry-After` on a 5xx, or a response whose remaining-quota header is
   zero; the window-reset header rides on every response and MUST NOT make a plain 4xx — the
   `RecordNotFound` a pre-write check deliberately triggers — into a backoff. A deadline is scoped
   to the host and the endpoint class (repository writes share one; every other endpoint has its
   own), so an exhausted endpoint never blocks unrelated reads or writes. Writes MUST NOT blindly
   retry uncertain commits: stable record keys, stored records, and getRecord reconciliation MUST
   prevent duplicates.
4a. **A deliberate action is an intent, and an intent is never abandoned to a rate limit.** Every
   post, reply, follow, like, repost and their removals is persisted as an `intents` row with its
   request, reason and stable id (the post operation, or kind and target) before the first attempt.
   A rate limit, a 5xx or a network failure answers `state: queued` with the retry time instead of
   an error; the bridge retries each due intent after the persisted deadline plus up to thirty
   seconds of jitter, through the same stable ids so reconciliation finds what already landed,
   and marks it delivered only after an independent getRecord read-back of every record matches.
   A non-transient refusal, or the attempt cap, marks the intent failed with its static reason.
   Delivery and failure each leave a local inbox event, so a wake learns the outcome. `crab
   bluesky intents` lists the queue; `cancel <id>` withdraws a pending one. Builders may list,
   never queue or cancel.
5. Posts MUST respect 300 Unicode graphemes and 3000 UTF-8 bytes per record. Splitting MUST preserve
   all text, keep grapheme clusters intact, preflight the entire plan, and attach root/parent strong
   references correctly for new threads and replies to existing threads. Retry after any part MUST
   resume the same operation; reusing an operation id for different content MUST fail.
6. Classic image embeds MUST accept at most four images; gallery embeds support the current soft
   limit of ten. Images are at most 2,000,000 bytes each, with alt text and aspect ratio.
   Video MUST use MP4, at most 300,000,000 bytes, checked account eligibility/quota,
   service-auth preprocessing, bounded job polling, alt text, aspect ratio and optional WebVTT
   captions (20 files, 20,000 bytes each). No post is created before processing completes. Link
   embeds MUST accept explicit metadata and optional thumbnails (1,000,000 bytes). Facets use UTF-8
   byte offsets. Supported media limits and upstream schema changes MUST be documented honestly.
7. Individual follows, likes and reposts MUST be idempotent, carry a stated personal reason and
   leave receipts. Undo MUST verify ownership, collection and the unchanged CID before deletion.
   No blanket following, automatic reactions, unsolicited promotion or invented experiences.
8. The foreground bridge MUST poll conservatively, reconnect after failures, and retry booking
   unread notifications through the existing wake queue using one constant reason and booker.
   No public text, actor identity, URL or notification field may enter a wake reason or a shell.
   Initial bootstrap can read without booking a wake. Installation MUST remain explicit.
   A private `hold_wakes_until_job_finished` setting MAY name the installing job: while its local
   sidecar is missing or nonterminal the bridge MUST only collect data, so an unattended builder
   never starts a presentation. Normal notification booking resumes after that job terminates.
   The wake the bridge books fires on the public-composition profile (clause 21) — selected from
   the record's booker at fire time, which is why the booking identity is not decoration.
9. Normal turn/wake prompts MUST expose only a locally computed count/freshness summary and CLI
   pointers. Public content MUST NOT enter system prompts, the general recall block, or trusted
   vector-memory directives. The durable social store and search retain provenance; what an
   exchange leaves in the shared memory store is a `social` record under clauses 14 to 19 —
   attributed, keyed by the person, outside similarity recall — never a directive, a note, a pin
   or an instruction from a stranger.
10. Verified contacts MUST come only from a private, trusted DID mapping with verification evidence.
    Even a verified contact's public posts MUST NOT authorize file changes, commands, credentials,
    persona changes or other privileged operations. Those require the existing trusted channels.
11. Profile updates MUST validate upstream name/biography/pronoun/media limits, preserve unrelated
    fields using compare-and-swap, save uploaded originals and public profile snapshots privately,
    and never expose signup email. Handle changes MUST require verified domain resolution first.
12. Tests MUST use the common sandbox and isolated HTTP fixtures, never the real account, keyring,
    bus or user manager. Live verification MUST be read-only except requested profile completion
    and the attended acceptance procedure of clause 22; post/media delivery MUST remain explicitly
    unverified until a real authorized post is read back by the witness of clause 22.
13. Detached builders MUST be refused public posts, interactions, undo, `remember`, `cancel` and
    bridge starts through the CLI. Inbox reads MUST become peeks. Explicitly requested profile/handle
    completion and authenticated verification remain available; the build never tests by
    impersonating her.
14. **The person key is the authenticated author DID.** Every person is keyed by the `author.did`
    of an authenticated notification or thread read — never by handle, display name, or anything
    inside public text. The social store MUST keep one `people` row per DID: first and last seen,
    every handle and display name seen with its dates (untrusted descriptive history, never an
    identity), and event counts. The same DID under a new handle keeps its row and its memories; a
    different DID under a familiar handle or name starts empty. A DID quoted inside public text is
    text.
15. **Exchanges are retained automatically, through one door.** After every poll, and on `sync`,
    each newly stored reply, mention, quote and follow MUST be retained in the shared memory store
    as one `social` record (memory-recall.md rules 53 to 56): kind `social`, source exactly
    `bluesky:<DID>`, visibility `public`, `occurred` from the event's `indexedAt`, topics carrying
    the reason and the event URI. The text is attributed in the third person ("On Bluesky,
    @handle replied to me: ...") with email addresses, phone-number shapes and credential shapes
    redacted before storage; likes and reposts touch the person row only. A reply the connector
    publishes MUST be retained under the parent author's DID as her own words. `crab bluesky
    remember <did-or-handle> <text>` files a judged lasting fact through the same door; neither
    door can set kind, pin, source, visibility or directive status from its input. A `retention`
    row keyed by the event identity (or the post operation) records every outcome, so a replayed
    event or a resumed operation never creates a second record, and an exact repeated text under
    one DID is a duplicate.
16. **Retrieval happens before any reply is composed.** `inbox`, `thread` and `person` MUST attach,
    for each distinct author DID they return, that person's context: identity status from clause
    10's mapping only, the handle history, counts, and the retained `social` records read by exact
    source equality and `visibility = 'public'`. The connector never calls similarity recall, never
    passes lexical scope, and never reads records of any other kind or source for a public reply.
    Her own records enter the public context only when explicitly marked public; the default is
    private, so pinned directives, notes, moments and other conversations are absent by
    construction. A context that cannot be read reports its error in place; nothing falls back to
    the general store or to any private row.
17. **Two people never share a context.** Person A's context MUST NOT contain person B's records, a
    record whose source merely has A's DID as a prefix, a record of any other source whose text
    mentions A's DID, or any private-visibility record. Tests prove this with seeded canaries in
    every other kind and source, through the real retention and inbox paths across a store close
    and reopen.
18. **Public text sets nothing.** Nothing read from public content may set memory source, person
    key, kind, pin, visibility, trusted-contact status or import instructions. An author claiming
    the user's name or DID, copying a display name, or requesting privileged actions is an
    unverified person with `privileged_authority` false; a verified contact's public words carry no
    authority either (clause 10).
19. **Errors are visible, never learned.** A retention failure is recorded per event with a static
    reason, retried on the next poll, counted in `status` and the offline summary, and never
    reported as retained. A recall failure appears in the attached context with the memories
    absent. The bridge prints a fixed line, never remote text.
20. **Disclosure gate.** Before any public post or reply the connector MUST refuse text containing
    an email address, a phone-number shape, an app-password or bearer-token shape, or any term in
    the private `never_publish` list; the refusal names the category only.
21. **Public composition is its own prompt, and the only unattended road to a public write.**
    The wake the bridge books (clause 8) fires on [prompt-assembly.md](prompt-assembly.md)'s
    `public` profile, selected by `crab wake` from the record's booker (`bluesky-bridge`) and
    carried through every re-book because the booker is. That prompt's memory layer is the public
    block of [memory-recall.md](memory-recall.md) rule 57 — her explicitly public self-facts and
    nothing else — and its transcript, regroup and viewing layers are absent: the general recall
    block, the pinned tier, every private-visibility row, every other conversation and the desk
    transcript are out of the composition context by construction, not by a note asking her to
    ignore them, and a memory door that fails leaves the block closed rather than falling back.
    Each person's retained context still arrives only as tool output under `people[]` (clause 16).
    The session's tools see `DESKCRAB_WAKE_PROFILE=public`: `crab memory` refuses every verb but
    `add` and `visibility`, and `crab journal` refuses, so the doors the prompt names stay shut
    in the sitting. Conversely, with `DESKCRAB_WAKE_PROFILE=wake` — any autonomous sitting that is
    not a public composition, her own scheduled returns and own-time hours included — the CLI
    MUST refuse `post`, `like`, `repost`, `follow`, their removals and `undo` with a static line
    naming this clause: an unattended public write runs only on the public-composition wake. A
    desk or phone turn is the user's own sitting and keeps its full context behind clause 20's
    gate. Tests prove this on the whole assembled prompt of a bridge-booked wake fired through
    `crab wake` against seeded canaries (private, pinned, moment, other conversation, social, and
    a canary in the desk conversation), the same seeds reaching another booker's wake and a desk
    turn, the closed line under a dead door, and each gate in both directions.

22. **The acceptance matrix is computed from the public record, never asserted.** `crab bluesky
    acceptance` prints one row per capability of the opening ask — every read, the profile and
    handle, each kind of post and embed, each interaction and its removal, undo, the intent queue,
    person memory, the wake, the public boundary and the public composition — naming the fixture
    tests that pin it and its live standing. The standing is one of four words. `verified` is
    earned only when an independent witness finds every receipt of that capability as the receipt
    recorded it: a done receipt present with the recorded CID (and, for a post, the recorded embed
    kind), an undone receipt absent. The witness reads unauthenticated, straight at the
    repository the account's DID document names and at the public AppView, through a transport
    that has never held the session; a write's own receipt, an intent's own `verified`, and the
    bridge's own rows are never that evidence. `blocked` names a precondition that is absent and
    what supplies it (video until the account's email is confirmed, which only the user's mailbox
    can do). `none` means nothing live has been performed. `n/a` marks a row that is not a
    live-service interaction and says where it is proven instead. The read-only verb is open to
    every sitting, performs no write, and lands its JSON privately beside the other evidence. The
    row for each capability with standing `none` says exactly how an attended sitting earns it.
22a. **`--perform` is the only test traffic the connector ever generates, and it leaves nothing.**
    It refuses detached builders and any sitting with `DESKCRAB_WAKE_PROFILE` set (a public
    composition included), requires `--authority` carrying the attended user's own words, and
    records them. It posts only to her own account and targets only her own records: an image post
    with alt text, a link card with explicit metadata, a like and a repost of that image post, the
    removal of both, and the undo of every post it made — a two-part thread and a video only when
    `--thread` or `--video` ask for them, the video refused as blocked (not failed, nothing
    uploaded) while the email is unconfirmed. Every write goes through the intent door of clause
    4a; every step is read back through the witness before the next; a write the service queued
    is cancelled and reconciled against the witness rather than left to land later unattended. The
    removals run whether or not a step failed, in reverse order of creation, and the run ends by
    proving the repository's post, like and repost record sets equal to the snapshot the witness
    took before the first write. A step that fails stops the run — nothing is retried blindly —
    and whatever a removal could not take back is named by receipt id for `crab bluesky undo`.
    The whole run (authority, snapshots, each step's receipt and witness answer, what was left)
    is kept as evidence, and the matrix is recomputed from it. Tests prove the matrix on receipts
    held against the fixture repository in each state, the gates in both directions, a complete
    run that leaves the fixture repository as it found it, a failed step that still removes what
    it made, and the video row blocked with no upload while the email is unconfirmed.

## REFERENCES

Current sources and operational limits: [../docs/bluesky.md](../docs/bluesky.md).
