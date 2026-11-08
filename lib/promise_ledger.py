"""promise_ledger — the one reader of sweep-row identity on the promise ledger.

specs/nightly.md rule 53f: every end-of-day sweep run stamps one `sweep_time`
before its first append and numbers its misses with a 1-based `item`, and a
later `type: sweep-resolution` row naming (day, sweep_time, item) settles that
one miss durably — fulfilled, struck, or booked. The grouping of raw sweep
rows into runs, the ordinals of rows that predate the identity, and the
matching of resolutions against both shapes live HERE and nowhere else:
`lib/night-work` reads owed work through this module, and
`lib/promise-check resolve` writes resolutions through it. Two readers with
two opinions of which row a resolution names would turn settled debt back
into owed work.

The legacy shape is why nearness, never equality, draws the run boundary: the
ledger appends stamp their own clock, so one run's rows can straddle a second
— the fifty misses of 2026-08-28 landed thirteen at 03:23:05 and thirty-seven
at 03:23:06, and the fifty reconciliation rows all name 03:23:05.

The ledger's third shape lives here too (rules 53k-53m): a commitment made
about a LATER DAY is retained by the sweep as a `type: due` row — origin day,
the promise, the moment as she stated it, and the `due` day counted from the
ORIGIN day, never the wall clock — and settled by a `type: due-outcome` row
naming its `due_id`. The id is derived from the origin day and the promise's
words so a day swept twice retains the row once, and the due-day arithmetic is
here beside the identity because both halves of the follow-up (retaining on
the origin night, asking on the due night) must agree on what "tomorrow" was.
"""

import datetime
import hashlib
import json
import re
import time

# Rows of one sweep run land moments apart; distinct runs of the same day
# (2026-08-26 was swept at 03:24 and again at 21:18) sit hours apart.
RUN_GAP_SECONDS = 300
# A resolution's sweep_time must land this close to a legacy run's first
# write to name it.
RESOLUTION_SLACK_SECONDS = 600


def parse_ts(ts):
    """The ledger's own timestamp shape, offset ignored: both sides of every
    match are written by the same machine. None when it will not parse."""
    try:
        return time.mktime(time.strptime(str(ts)[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


def append_row(path, fields):
    """One JSON line onto the ledger, flocked like the journal: several
    turns finish together and an interleaved partial line poisons the sweep's
    night. `time` is stamped first; `epoch`, `pid` and `item` are kept as
    integers. The one writer: lib/promise-check's ledger_append and its
    sweep's settle pass both come through here."""
    import fcntl
    import os
    rec = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    for k, v in fields.items():
        if k in ("epoch", "pid", "item") and isinstance(v, str) and v.isdigit():
            v = int(v)
        rec[k] = v
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        f.flush()
    return rec


def read_rows(path):
    """Every parseable JSON object on the ledger, in file order. Raises
    OSError so the caller can present an unreadable ledger AS unreadable."""
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if isinstance(d, dict):
                rows.append(d)
    return rows


def sweep_runs(rows):
    """The `type: sweep` rows grouped into runs, in file order.

    Each run is a dict: `day`, `time` (the run's identity — the explicit
    `sweep_time` when the run stamped one, else the first row's own write
    time), `epoch` (that identity parsed, or None), and `rows`, a list of
    (item, row) with the explicit `item` honoured and the legacy ordinal
    counted 1-based within the run.
    """
    runs = []
    cur = None
    for d in rows:
        if d.get("type") != "sweep":
            continue
        day = d.get("day")
        explicit = d.get("sweep_time")
        epoch = parse_ts(explicit or d.get("time"))
        boundary = (
            cur is None
            or day != cur["day"]
            # An explicit identity groups by equality alone; a change of
            # shape (stamped beside unstamped) is always a new run.
            or bool(explicit) != bool(cur["explicit"])
            or (explicit and explicit != cur["time"])
            # Legacy rows cluster by nearness in write time.
            or (not explicit
                and epoch is not None and cur["epoch"] is not None
                and abs(epoch - cur["epoch"]) > RUN_GAP_SECONDS)
        )
        if boundary:
            cur = {"day": day, "explicit": bool(explicit),
                   "time": str(explicit) if explicit else str(d.get("time", "")),
                   "epoch": epoch, "rows": []}
            runs.append(cur)
        item = d.get("item")
        if not isinstance(item, int):
            item = len(cur["rows"]) + 1
        cur["rows"].append((item, d))
    return runs


def match_run(runs, day, sweep_time):
    """The run a resolution names: exact identity first, then — for the
    legacy shape — the day's nearest run within the slack."""
    for r in runs:
        if r["day"] == day and r["time"] == str(sweep_time):
            return r
    target = parse_ts(sweep_time)
    if target is None:
        return None
    best = None
    for r in runs:
        # A stamped run has an exact durable identity.  The slack exists only
        # for rows written before that identity did; letting a near timestamp
        # name a stamped run would silently settle the wrong debt.
        if r["explicit"] or r["day"] != day or r["epoch"] is None:
            continue
        delta = abs(r["epoch"] - target)
        if delta <= RESOLUTION_SLACK_SECONDS and (best is None or delta < best[0]):
            best = (delta, r)
    return best[1] if best else None


def resolved_items(rows):
    """The set of (run id, item) pairs the ledger's resolution rows settle.
    Any of the three decisions settles: fulfilled, struck, and booked debt
    are all debt with a named disposition. Returns (runs, resolved_set)."""
    runs = sweep_runs(rows)
    resolved = set()
    for d in rows:
        if d.get("type") != "sweep-resolution":
            continue
        if d.get("decision") not in ("fulfilled", "struck", "booked"):
            continue
        item = d.get("item")
        if not isinstance(item, int):
            continue
        run = match_run(runs, d.get("day"), d.get("sweep_time"))
        if run is not None:
            resolved.add((id(run), item))
    return runs, resolved


def owed(rows, cut_epoch):
    """The recent sweep rows no resolution has settled.

    Returns (owed_rows, resolved_count): the unresolved `type: sweep` rows
    whose write time is at or after cut_epoch (an unparseable time counts as
    recent — surfacing errs loud), in file order, and the count of recent
    rows a resolution excluded — stated, never silently dropped
    (specs/nightly.md rule 58b).
    """
    runs, resolved = resolved_items(rows)
    owed_rows, resolved_count = [], 0
    for run in runs:
        for item, d in run["rows"]:
            when = parse_ts(d.get("time"))
            if when is not None and when < cut_epoch:
                continue
            if (id(run), item) in resolved:
                resolved_count += 1
            else:
                owed_rows.append(d)
    return owed_rows, resolved_count


def latest_run(rows, day):
    """The day's newest sweep run — the one the morning after resolves."""
    runs = [r for r in sweep_runs(rows) if r["day"] == day]
    return runs[-1] if runs else None


# ---------------------------------------------------------------------------
# Later-day commitments (specs/nightly.md rules 53k-53m).
# ---------------------------------------------------------------------------

# How many days past due a pending row may stand unanswered before the next
# sweep surfaces it unjudged (rule 53m). The night judge can be down for a
# night or two; a week of silence is a commitment nobody is going to judge.
DUE_GRACE_DAYS = 7

_WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday",
             "saturday", "sunday")
_WEEKDAY_SHORT = {d[:3]: i for i, d in enumerate(_WEEKDAYS)}
_WORD_NUMBERS = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
                 "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                 "ten": 10, "couple": 2, "few": 3}


def norm_promise(text):
    """The promise's words as identity: whitespace collapsed, case folded,
    the quote marks and trailing punctuation the judge may or may not have
    kept stripped. Two sweeps quoting one sentence must agree."""
    t = " ".join(str(text or "").split()).strip()
    t = t.strip("\"'\u201c\u201d\u2018\u2019")
    t = t.rstrip(".,;:!?").strip()
    return t.casefold()


def due_identity(day, promise):
    """The durable id of a retained later-day commitment: the origin day and
    a short digest of the promise's normalised words."""
    h = hashlib.sha1(norm_promise(promise).encode("utf-8")).hexdigest()[:10]
    return "%s:%s" % (day, h)


def parse_day(day):
    """A YYYY-MM-DD string as a date, or None."""
    try:
        return datetime.date.fromisoformat(str(day)[:10])
    except (TypeError, ValueError):
        return None


def resolve_due_day(origin_day, when):
    """The day a stated moment falls on, counted from the ORIGIN day.

    Returns (due_day as YYYY-MM-DD, how) where `how` is one of:
      "resolved"  — the words were read ("tomorrow", "in 3 days", "friday",
                    "next week", a dated day);
      "same-day"  — the moment lies within the origin day itself ("tonight",
                    "this afternoon", "later", a bare clock time): not a
                    later-day commitment at all, the caller's to judge as the
                    day's own;
      "floor"     — the words could not be read; the next day is the floor
                    (rule 53k), the stated words kept beside it by the caller.
    An origin day that will not parse is itself the floor's base: None.
    """
    base = parse_day(origin_day)
    if base is None:
        return None, "floor"
    w = " ".join(str(when or "").split()).strip().casefold()
    w = w.strip("\"'\u201c\u201d\u2018\u2019").rstrip(".,;:!?")
    w = re.sub(r"^(on|by|at|around|about|before|until|till)\s+", "", w)
    w = re.sub(r"^(the\s+)?(early|late|first\s+thing|end\s+of)\s+", "", w)
    if not w or w in ("unknown", "?"):
        return (base + datetime.timedelta(days=1)).isoformat(), "floor"

    # A dated day in her words, ISO first.
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", w)
    if m:
        d = parse_day(m.group(1))
        if d is not None:
            return d.isoformat(), ("same-day" if d <= base else "resolved")

    # Within the day: no later-day commitment here.
    same_day = ("tonight", "this evening", "this afternoon", "this morning",
                "later today", "today", "later", "shortly", "soon", "now",
                "in a moment", "in a minute", "in a bit", "after this",
                "noon", "midday", "midnight", "this sitting", "in a while",
                "end of day", "by end of day", "eod")
    if w in same_day or re.fullmatch(r"\d{1,2}(:\d{2})?\s*(am|pm)?", w) \
            or re.fullmatch(r"in\s+(a\s+)?(\w+\s+)?(hour|hours|minute|minutes|min|mins|hr|hrs)", w):
        return base.isoformat(), "same-day"

    # Tomorrow in any dress: "tomorrow", "tomorrow morning", "first thing
    # tomorrow", "tomorrow night", "by tomorrow".
    if "day after tomorrow" in w or "overmorrow" in w:
        return (base + datetime.timedelta(days=2)).isoformat(), "resolved"
    if "tomorrow" in w or "tmrw" in w:
        return (base + datetime.timedelta(days=1)).isoformat(), "resolved"

    # "in N days" / "in a couple of days" / "N days from now".
    m = re.fullmatch(r"(?:in|within)\s+(?:the\s+next\s+)?(?:a\s+)?(\w+)(?:\s+of)?\s+days?(?:\s+or\s+so)?", w) \
        or re.fullmatch(r"(?:a\s+)?(\w+)\s+days?\s+(?:from\s+now|out|hence|later)", w)
    if m:
        n = m.group(1)
        n = int(n) if n.isdigit() else _WORD_NUMBERS.get(n)
        if n:
            return (base + datetime.timedelta(days=n)).isoformat(), "resolved"
    m = re.fullmatch(r"(?:in|within)\s+(?:a\s+)?(\w+)(?:\s+of)?\s+weeks?", w) \
        or re.fullmatch(r"(?:a\s+)?(\w+)\s+weeks?\s+(?:from\s+now|out|hence|later)", w)
    if m:
        n = m.group(1)
        n = int(n) if n.isdigit() else _WORD_NUMBERS.get(n)
        if n:
            return (base + datetime.timedelta(days=7 * n)).isoformat(), "resolved"
    if w in ("next week", "the next week", "in the next week", "over the weekend",
             "this weekend", "the weekend", "at the weekend"):
        if "weekend" in w:
            # The coming Saturday; from a Saturday or Sunday, the next one.
            ahead = (5 - base.weekday()) % 7 or 7
            return (base + datetime.timedelta(days=ahead)).isoformat(), "resolved"
        return (base + datetime.timedelta(days=7)).isoformat(), "resolved"
    if w in ("next month", "in a month"):
        return (base + datetime.timedelta(days=30)).isoformat(), "resolved"

    # A weekday, possibly dressed: "friday", "on friday morning", "next
    # monday", "fri". The next such day strictly after the origin day.
    for tok in re.findall(r"[a-z]+", w):
        idx = _WEEKDAYS.index(tok) if tok in _WEEKDAYS else _WEEKDAY_SHORT.get(tok)
        if idx is not None:
            ahead = (idx - base.weekday()) % 7 or 7
            return (base + datetime.timedelta(days=ahead)).isoformat(), "resolved"

    return (base + datetime.timedelta(days=1)).isoformat(), "floor"


def due_rows(rows):
    """Every `type: due` row in file order, each with its due_id filled in
    (derived when a row predates the field)."""
    out = []
    for d in rows:
        if d.get("type") != "due":
            continue
        if not d.get("due_id"):
            d = dict(d)
            d["due_id"] = due_identity(d.get("day"), d.get("promise"))
        out.append(d)
    return out


def due_outcomes(rows):
    """The due_ids a `type: due-outcome` row has settled — kept, missed, or
    lapsed — mapped to the newest such row."""
    settled = {}
    for d in rows:
        if d.get("type") != "due-outcome":
            continue
        if d.get("decision") not in ("kept", "missed", "lapsed"):
            continue
        if d.get("due_id"):
            settled[str(d["due_id"])] = d
    return settled


def retained_due(rows, due_id):
    """True when a `type: due` row with this id already stands."""
    return any(d.get("due_id") == due_id for d in due_rows(rows))


def pending_due(rows, swept_day, grace_days=DUE_GRACE_DAYS):
    """The retained later-day commitments that have fallen due by the swept
    day and no outcome has settled, split by the grace line.

    Returns (ask, lapsed): `ask` — the rows whose due day is on or before the
    swept day and within the grace, oldest due first, in file order within a
    day, for the judge; `lapsed` — the rows more than grace_days past due,
    which the sweep surfaces unjudged (rule 53m). Rows due after the swept
    day are neither: they are not asked about before their day. A row whose
    due day will not parse counts as fallen due — surfacing errs loud.
    """
    swept = parse_day(swept_day)
    settled = due_outcomes(rows)
    ask, lapsed = [], []
    if swept is None:
        return ask, lapsed
    for d in due_rows(rows):
        if str(d["due_id"]) in settled:
            continue
        due = parse_day(d.get("due"))
        if due is None:
            lapsed.append(d)
            continue
        if due > swept:
            continue
        if (swept - due).days > grace_days:
            lapsed.append(d)
        else:
            ask.append(d)
    key = lambda d: (parse_day(d.get("due")) or swept)
    ask.sort(key=key)
    return ask, lapsed
