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
"""

import json
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
