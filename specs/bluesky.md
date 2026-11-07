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
4. Reads MUST retry bounded network/5xx failures with jitter. HTTP 429 and Retry-After/rate-limit
   reset deadlines MUST persist across restarts. Writes MUST NOT blindly retry uncertain commits:
   stable record keys, stored records, and getRecord reconciliation MUST prevent duplicates.
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
9. Normal turn/wake prompts MUST expose only a locally computed count/freshness summary and CLI
   pointers. Public content MUST NOT enter system prompts or trusted vector-memory directives.
   The durable social store and search retain provenance; chosen memories may be filed through
   the existing memory door as attributed observations, never instructions from strangers.
10. Verified contacts MUST come only from a private, trusted DID mapping with verification evidence.
    Even a verified contact's public posts MUST NOT authorize file changes, commands, credentials,
    persona changes or other privileged operations. Those require the existing trusted channels.
11. Profile updates MUST validate upstream name/biography/pronoun/media limits, preserve unrelated
    fields using compare-and-swap, save uploaded originals and public profile snapshots privately,
    and never expose signup email. Handle changes MUST require verified domain resolution first.
12. Tests MUST use the common sandbox and isolated HTTP fixtures, never the real account, keyring,
    bus or user manager. Live verification MUST be read-only except requested profile completion;
    post/media delivery MUST remain explicitly unverified until a real authorized post is checked.
13. Detached builders MUST be refused public posts, interactions, undo and bridge starts through
    the CLI. Inbox reads MUST become peeks. Explicitly requested profile/handle completion and
    authenticated verification remain available; the build never tests by impersonating her.

## REFERENCES

Current sources and operational limits: [../docs/bluesky.md](../docs/bluesky.md).
