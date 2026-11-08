#!/usr/bin/env python3
"""The durable token ledger (specs/metrics.md).

One compact JSONL record per CLI attempt, parsed out of the stream file the
run just wrote — or, for backfill, out of the surviving archived streams and
her own CLI transcripts. Stdlib only, no model call anywhere (spec rule 5),
and the `record` path always exits 0: a ledger that cannot be written costs
the run that hosts it nothing (rule 6).

Subcommands:
  record   <stream> --kind K [--model M] [--effort E] [--account A] ...
  report   [--date YYYY-MM-DD] [--dir DIR]
  aggregate [--days N] [--dir DIR]
  backfill [--dir DIR] [--streams DIR] [--claude-dirs A:B] [--her-cwds A:B]
"""

import argparse
import fcntl
import json
import os
import re
import sys
import time

# The chain's token for account 1, the login with no config dir. The
# accounts are a flat numbered list — no login outranks another.
ACCOUNT_ONE_TOKEN = "-"

# The shared limit signature, from lib/common.sh by way of the environment
# (account-fallback.md rule 13: one signature, never a second copy that ages
# on its own). The spelling below is a last resort for detached callers that
# arrive without the export; it mirrors CLAUDE_LIMIT_RE's default.
_DEFAULT_LIMIT_RE = (
    "out of usage credits|usage limit reached|session limit reached|"
    "5-hour limit|weekly limit|hit your usage limit|hit your session limit|"
    "credit balance is too low|insufficient credit|out of extra usage|"
    "reached your .* limit|run /usage-credits|not logged in|please run /login"
)


def limit_re():
    raw = os.environ.get("DESKCRAB_CLAUDE_LIMIT_RE", "").strip() \
        or _DEFAULT_LIMIT_RE
    try:
        return re.compile(raw, re.I)
    except re.error:
        return re.compile(_DEFAULT_LIMIT_RE, re.I)


def metrics_dir(arg=None):
    if arg:
        return arg
    env = os.environ.get("DESKCRAB_METRICS_DIR")
    if env:
        return env
    data = os.environ.get("XDG_DATA_HOME") \
        or os.path.expanduser("~/.local/share")
    return os.path.join(data, "deskcrab", "metrics")


def account_name(token):
    """A login's canonical name. The live wire speaks NUMBERS: the flat
    walks hand this ledger the account number itself, and the deployed swap
    markers say "account 1 -> account 2 (limit refusal)" — both land as
    `account-N` directly, no chain lookup needed. Everything else is
    accepted for BACKFILL only, from streams written before the flat
    rework: `primary` (what the old markers spelled account 1 as on the
    wire, never what this ledger writes), the chain's `-` token, an absent
    override, and account 1's own config directory all mean `account-1`; a
    config-dir path keeps its basename, which the chain resolves."""
    token = str(token or "").strip()
    if not token or token in (ACCOUNT_ONE_TOKEN, "primary"):
        return "account-1"
    m = re.fullmatch(r"account[- ](\d+)", token) \
        or re.fullmatch(r"(\d+)", token)
    if m:
        return "account-%d" % int(m.group(1))
    if os.path.expanduser(token.rstrip("/")) \
            == os.path.expanduser("~/.claude"):
        return "account-1"
    return os.path.basename(token.rstrip("/")) or "account-1"


def parse_chain(raw):
    """The CONFIGURED chain, account 1 first: account_n is a position in
    this list (spec rule 3), never in the rotated walk."""
    toks = [t for t in re.split(r"[:\s]+", raw or "") if t]
    names = []
    for t in [ACCOUNT_ONE_TOKEN] + toks:
        n = account_name(t)
        if n not in names:
            names.append(n)
    return names


def account_number(name, chain_names):
    """A canonical `account-N` name IS its number; anything else — a
    backfill-era basename — is a position in the configured chain."""
    m = re.fullmatch(r"account-(\d+)", name or "")
    if m:
        return int(m.group(1))
    try:
        return chain_names.index(name) + 1
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Stream parsing.
# --------------------------------------------------------------------------

def _events(path):
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(d, dict):
                out.append(d)
    return out


def _is_synthetic(ev):
    return bool(ev.get("is_api_error_message")) \
        or (ev.get("message") or {}).get("model") == "<synthetic>"


def _is_error_result(ev):
    """An error result — including the type-less `is_error` line the CLI has
    been observed to emit on a cut (account-fallback.md rule 12d)."""
    if not ev.get("is_error"):
        return False
    return ev.get("type") in (None, "result")


def _is_traffic(ev):
    """Model traffic: what makes a slice an attempt that happened. A result
    line with no usage and no error is the caller's own terminator, not a
    result (spec rule 8) — a stream holding only that never booted, and a
    record for it would be a status-ok run that never was."""
    t = ev.get("type")
    if t == "result":
        return isinstance(ev.get("usage"), dict) or bool(ev.get("is_error"))
    if t in ("assistant", "user", "stream_event", "rate_limit_event"):
        return True
    return t == "system" and ev.get("subtype") == "init"


def _genuine_text(ev):
    """Genuine model output in this event: a non-synthetic assistant text or
    tool_use block (the same question claude_stream_refusal asks)."""
    if ev.get("type") != "assistant" or _is_synthetic(ev):
        return False
    for b in (ev.get("message") or {}).get("content") or []:
        if isinstance(b, dict) and b.get("type") in ("text", "tool_use"):
            return True
    return False


def _slice_attempts(events):
    """Split a stream's events into attempt slices on system/init boundaries.
    Events before the first init ride with the first attempt; a stream with no
    init at all is one attempt (spec rule 12)."""
    marks = [i for i, ev in enumerate(events)
             if ev.get("type") == "system" and ev.get("subtype") == "init"]
    if not marks:
        return [events]
    # Anything before the first init (the session note, hook lines) rides
    # inside the first slice, because prev starts at 0.
    slices, prev = [], 0
    for m in marks[1:]:
        slices.append(events[prev:m])
        prev = m
    slices.append(events[prev:])
    return slices


def _swap_accounts(events, hint):
    """The account of each attempt, read off the swap marker notes
    (account-fallback.md rule 24). Returns a list indexable by attempt."""
    swaps = [ev for ev in events
             if ev.get("type") == "deskcrab_note"
             and ev.get("note") == "account-swap"]
    pairs = []
    for ev in swaps:
        m = re.match(r"(.+?) -> (.+?) \(", ev.get("detail") or "")
        if m:
            pairs.append((m.group(1).strip(), m.group(2).strip()))
    if not pairs:
        return [account_name(hint)] if hint else [None]
    accounts = [account_name(pairs[0][0])]
    accounts += [account_name(p[1]) for p in pairs]
    return accounts


def _usage_fields(u):
    return {
        "input": int(u.get("input_tokens") or 0),
        "output": int(u.get("output_tokens") or 0),
        "cache_create": int(u.get("cache_creation_input_tokens") or 0),
        "cache_read": int(u.get("cache_read_input_tokens") or 0),
    }


def _dedupe_assistant_usage(events):
    """When no result totals exist: usage per distinct message id,
    synthetic events excluded (spec rules 9-10). The CLI repeats one message's
    usage across its streamed deltas, so the id is the unit; the per-message
    numbers are a start-of-message snapshot, hence `approx`."""
    per_id = {}
    models = {}
    for ev in events:
        msg = None
        if ev.get("type") == "assistant" and not _is_synthetic(ev):
            msg = ev.get("message") or {}
        elif ev.get("type") == "stream_event":
            e = ev.get("event") or {}
            if e.get("type") == "message_start":
                msg = e.get("message") or {}
        if not msg:
            continue
        u = msg.get("usage")
        mid = msg.get("id")
        if not u or not mid:
            continue
        f = _usage_fields(u)
        old = per_id.get(mid)
        if old is None:
            per_id[mid] = f
        else:
            for k in f:
                old[k] = max(old[k], f[k])
        if msg.get("model"):
            models[mid] = msg["model"]
    by_model = {}
    for mid, f in per_id.items():
        m = models.get(mid)
        t = by_model.setdefault(m, {"input": 0, "output": 0,
                                    "cache_create": 0, "cache_read": 0})
        for k in f:
            t[k] += f[k]
    return by_model


def _attempt_status(events, sig):
    """ok / refused / cut / error, from the CLI's own events only
    (spec rule 11; account-fallback.md rules 12-12d)."""
    genuine = any(_genuine_text(ev) for ev in events)
    cli_text = []
    for ev in events:
        if ev.get("type") == "assistant" and _is_synthetic(ev):
            for b in (ev.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "text":
                    cli_text.append(b.get("text") or "")
        if _is_error_result(ev):
            cli_text.append(str(ev.get("result") or ""))
    err = any(_is_error_result(ev) for ev in events)
    limited = any(sig.search(t) for t in cli_text if t)
    if limited and not genuine:
        return "refused"
    if limited and genuine and err:
        return "cut"
    if err and not genuine:
        return "error"
    return "ok"


def parse_stream(path, kind, model="", effort="", account_hint="",
                 chain_names=None, duration=None, pid=None, src="live"):
    """The stream file a run just wrote -> a list of ledger records, one per
    attempt per model (spec rules 2-3, 8-12). Never raises on content."""
    events = _events(path)
    if not events:
        return []
    sig = limit_re()
    slices = _slice_attempts(events)
    accounts = _swap_accounts(events, account_hint)
    chain_names = chain_names or []
    try:
        ts_base = os.path.getmtime(path)
    except OSError:
        ts_base = time.time()
    records = []
    for i, sl in enumerate(slices):
        # A slice with no model traffic at all (the caller's usage-less
        # terminator, a lone note) is not an attempt that happened.
        if not any(_is_traffic(ev) for ev in sl):
            continue
        init = next((ev for ev in sl
                     if ev.get("type") == "system"
                     and ev.get("subtype") == "init"), {})
        result = None
        for ev in sl:
            if ev.get("type") == "result" and isinstance(ev.get("usage"),
                                                         dict):
                result = ev
        status = _attempt_status(sl, sig)
        acct = accounts[i] if i < len(accounts) else None
        base = {
            "ts": round(ts_base, 3),
            "kind": kind,
            "effort": effort or "",
            "account": acct,
            "account_n": account_number(acct, chain_names) if acct else None,
            "attempt": i + 1,
            "attempts": len(slices),
            "status": status,
            "src": src,
        }
        if pid:
            base["pid"] = int(pid)
        sid = init.get("session_id") or next(
            (ev.get("session_id") for ev in sl if ev.get("session_id")), None)
        if sid:
            base["sid"] = sid
        dur = None
        for ev in sl:
            if _is_error_result(ev) or (ev.get("type") == "result"
                                        and "duration_ms" in ev):
                if ev.get("duration_ms") is not None:
                    dur = ev["duration_ms"] / 1000.0
                elif ev.get("duration_api_ms") is not None:
                    dur = ev["duration_api_ms"] / 1000.0
        if result is not None:
            model_usage = result.get("modelUsage")
            if isinstance(model_usage, dict) and model_usage:
                for mname, mu in model_usage.items():
                    rec = dict(base)
                    rec["model"] = mname
                    rec["input"] = int(mu.get("inputTokens") or 0)
                    rec["output"] = int(mu.get("outputTokens") or 0)
                    rec["cache_create"] = int(
                        mu.get("cacheCreationInputTokens") or 0)
                    rec["cache_read"] = int(
                        mu.get("cacheReadInputTokens") or 0)
                    if mu.get("costUSD") is not None:
                        rec["cost"] = round(float(mu["costUSD"]), 6)
                    if dur is not None:
                        rec["duration"] = round(dur, 3)
                    records.append(rec)
            else:
                # The init event's model name is the resolved one; the
                # caller's alias ("opus") only stands in when the stream
                # never said.
                rec = dict(base)
                rec["model"] = init.get("model") or model or ""
                rec.update(_usage_fields(result["usage"]))
                if result.get("total_cost_usd") is not None:
                    rec["cost"] = round(float(result["total_cost_usd"]), 6)
                if dur is not None:
                    rec["duration"] = round(dur, 3)
                records.append(rec)
        else:
            by_model = _dedupe_assistant_usage(sl)
            if by_model:
                for mname, f in by_model.items():
                    rec = dict(base)
                    rec["model"] = mname or model or init.get("model") or ""
                    rec.update(f)
                    rec["approx"] = True
                    if dur is not None:
                        rec["duration"] = round(dur, 3)
                    records.append(rec)
            else:
                # A refusal or a crash before any usage: the attempt is still
                # the fact the ledger keeps (spec rule 11).
                rec = dict(base)
                rec["model"] = init.get("model") or model or ""
                rec.update({"input": 0, "output": 0,
                            "cache_create": 0, "cache_read": 0})
                if dur is not None:
                    rec["duration"] = round(dur, 3)
                records.append(rec)
    # The caller's wall-clock duration lands on the last record when the
    # stream itself carried none.
    if duration is not None and records and "duration" not in records[-1]:
        try:
            records[-1]["duration"] = round(float(duration), 3)
        except (TypeError, ValueError):
            pass
    return records


# --------------------------------------------------------------------------
# The ledger files.
# --------------------------------------------------------------------------

def day_file(mdir, ts):
    return os.path.join(
        mdir, "tokens-" + time.strftime("%Y-%m-%d", time.localtime(ts))
        + ".jsonl")


def append_records(mdir, records):
    """Whole lines under an exclusive lock (spec rule 7)."""
    if not records:
        return
    by_file = {}
    for r in records:
        by_file.setdefault(day_file(mdir, r.get("ts") or time.time()),
                           []).append(r)
    os.makedirs(mdir, exist_ok=True)
    for path, recs in by_file.items():
        with open(path, "a", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            for r in recs:
                fh.write(json.dumps(r, ensure_ascii=False,
                                    separators=(",", ":")) + "\n")
            fh.flush()


def read_day(mdir, date):
    path = os.path.join(mdir, "tokens-%s.jsonl" % date)
    out = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(d, dict):
                    out.append(d)
    except OSError:
        pass
    return out


def ledger_days(mdir):
    try:
        names = os.listdir(mdir)
    except OSError:
        return []
    days = []
    for n in names:
        m = re.match(r"tokens-(\d{4}-\d{2}-\d{2})\.jsonl$", n)
        if m:
            days.append(m.group(1))
    return sorted(days)


# --------------------------------------------------------------------------
# Aggregation (spec rules 20, 22).
# --------------------------------------------------------------------------

def _hour_of(rec):
    return int(time.strftime("%H", time.localtime(rec.get("ts") or 0)))


def aggregate(mdir, days=7, until=None):
    """Hour buckets over the last `days` ledger days: keyed by date, hour,
    kind, model, effort, account, status; summed tokens, cost, duration and
    count. Months of ledger stay a few thousand rows (spec rule 22)."""
    until = until or time.strftime("%Y-%m-%d")
    wanted = [d for d in ledger_days(mdir) if d <= until][-max(1, days):]
    buckets = {}
    for date in wanted:
        for rec in read_day(mdir, date):
            key = (date, _hour_of(rec), rec.get("kind") or "?",
                   rec.get("model") or "?", rec.get("effort") or "",
                   rec.get("account") or "?", rec.get("status") or "?")
            b = buckets.get(key)
            if b is None:
                b = buckets[key] = {
                    "d": key[0], "h": key[1], "kind": key[2],
                    "model": key[3], "effort": key[4], "account": key[5],
                    "status": key[6], "n": 0, "in": 0, "out": 0,
                    "cc": 0, "cr": 0, "cost": 0.0, "dur": 0.0,
                }
            b["n"] += 1
            b["in"] += int(rec.get("input") or 0)
            b["out"] += int(rec.get("output") or 0)
            b["cc"] += int(rec.get("cache_create") or 0)
            b["cr"] += int(rec.get("cache_read") or 0)
            b["cost"] += float(rec.get("cost") or 0)
            b["dur"] += float(rec.get("duration") or 0)
    rows = sorted(buckets.values(),
                  key=lambda b: (b["d"], b["h"], b["kind"], b["model"]))
    for b in rows:
        b["cost"] = round(b["cost"], 6)
        b["dur"] = round(b["dur"], 3)
    return {"days": wanted, "buckets": rows}


def _fmt_n(n):
    if n >= 10_000_000:
        return "%.1fM" % (n / 1e6)
    if n >= 10_000:
        return "%.0fk" % (n / 1e3)
    return str(n)


def report(mdir, date):
    recs = read_day(mdir, date)
    if not recs:
        print("no token records for %s" % date)
        return
    def sums(rows):
        return (sum(int(r.get("input") or 0) for r in rows),
                sum(int(r.get("output") or 0) for r in rows),
                sum(int(r.get("cache_create") or 0) for r in rows),
                sum(int(r.get("cache_read") or 0) for r in rows),
                sum(float(r.get("cost") or 0) for r in rows))
    ti, to, tcc, tcr, tc = sums(recs)
    print("tokens %s — %s in / %s out / %s cache-create / %s cache-read"
          " — %d attempts%s"
          % (date, _fmt_n(ti), _fmt_n(to), _fmt_n(tcc), _fmt_n(tcr),
             len(recs), (", $%.2f" % tc) if tc else ""))
    for label, keyf in (("by kind", lambda r: r.get("kind") or "?"),
                        ("by model", lambda r: r.get("model") or "?")):
        groups = {}
        for r in recs:
            groups.setdefault(keyf(r), []).append(r)
        print(label + ":")
        for k in sorted(groups,
                        key=lambda k: -sums(groups[k])[1]):
            gi, go, gcc, gcr, gc = sums(groups[k])
            refused = sum(1 for r in groups[k]
                          if r.get("status") in ("refused", "cut"))
            print("  %-16s %6s in %8s out %8s cc %9s cr  %3d runs%s%s"
                  % (k, _fmt_n(gi), _fmt_n(go), _fmt_n(gcc), _fmt_n(gcr),
                     len(groups[k]),
                     (" $%.2f" % gc) if gc else "",
                     (" (%d limited)" % refused) if refused else ""))


# --------------------------------------------------------------------------
# Backfill (spec rules 17-19).
# --------------------------------------------------------------------------

def _state_load(mdir):
    try:
        with open(os.path.join(mdir, "backfill-state.json")) as fh:
            d = json.load(fh)
            return d if isinstance(d, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _state_save(mdir, state):
    os.makedirs(mdir, exist_ok=True)
    tmp = os.path.join(mdir, "backfill-state.json.new")
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, os.path.join(mdir, "backfill-state.json"))


def _seen_sids(mdir):
    sids = set()
    for d in ledger_days(mdir):
        for rec in read_day(mdir, d):
            if rec.get("sid"):
                sids.add(rec["sid"])
    return sids


def _already(state, path):
    try:
        st = os.stat(path)
    except OSError:
        return True
    old = state.get(path)
    return bool(old and old.get("size") == st.st_size
                and old.get("mtime") == int(st.st_mtime))


def _mark(state, path):
    try:
        st = os.stat(path)
        state[path] = {"size": st.st_size, "mtime": int(st.st_mtime)}
    except OSError:
        pass


def _stream_kind(events):
    """The archived stream's own first line names its session
    (claim_debuglog); map the registry phrase to a ledger kind."""
    for ev in events[:3]:
        if ev.get("type") == "deskcrab_note" and ev.get("note") == "session":
            detail = (ev.get("detail") or "").lower()
            if "wake" in detail:
                return "wake", False
            if "phone" in detail:
                return "phone", False
            if "desktop" in detail or "desk" in detail:
                return "turn", False
            if "job" in detail:
                return "job", False
    return "turn", True


def _slugify(path):
    return re.sub(r"[^A-Za-z0-9-]", "-", path)


def _her_cwds(raw):
    if raw:
        return [p for p in raw.split(":") if p]
    out = []
    proj = os.environ.get("PROJECT_DIR")
    if proj:
        out.append(proj)
    run = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    out.append(os.path.join(run, "deskcrab-classify"))
    out.append(os.path.join(run, "deskcrab-chess-mover"))
    return out


def _claude_dirs(raw):
    if raw:
        return [p for p in re.split(r"[:\s]+", raw) if p]
    dirs = [os.path.expanduser("~/.claude")]
    for d in re.split(r"[:\s]+",
                      os.environ.get("CLAUDE_FALLBACK_CONFIG_DIR", "")):
        if d:
            dirs.append(os.path.expanduser(os.path.expandvars(d)))
    return dirs


def _transcript_records(path, kind):
    """One session transcript -> records summed per model, deduplicated by
    request id (spec rule 17). Approximate by construction."""
    per_req = {}
    models = {}
    first_ts = None
    first_user = ""
    sid = None
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return []
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(d, dict):
                continue
            sid = sid or d.get("sessionId")
            ts = d.get("timestamp")
            if first_ts is None and ts:
                try:
                    first_ts = time.mktime(time.strptime(
                        ts[:19], "%Y-%m-%dT%H:%M:%S"))
                except ValueError:
                    pass
            if d.get("type") == "user" and not first_user:
                m = d.get("message") or {}
                c = m.get("content")
                if isinstance(c, str):
                    first_user = c[:200]
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            if msg.get("model") == "<synthetic>":
                continue
            u = msg.get("usage")
            rid = d.get("requestId") or msg.get("id")
            if not u or not rid:
                continue
            f = _usage_fields(u)
            old = per_req.get(rid)
            if old is None:
                per_req[rid] = f
            else:
                for k in f:
                    old[k] = max(old[k], f[k])
            if msg.get("model"):
                models[rid] = msg["model"]
    if not per_req:
        return []
    if kind == "turn" and first_user.startswith("(Nobody is talking to you"):
        kind = "wake"
    by_model = {}
    for rid, f in per_req.items():
        t = by_model.setdefault(models.get(rid, ""),
                                {"input": 0, "output": 0,
                                 "cache_create": 0, "cache_read": 0})
        for k in f:
            t[k] += f[k]
    ts = first_ts or os.path.getmtime(path)
    out = []
    for mname, f in by_model.items():
        rec = {"ts": round(ts, 3), "kind": kind, "model": mname,
               "effort": "", "account": None, "account_n": None,
               "attempt": 1, "attempts": 1, "status": "ok",
               "src": "transcript", "approx": True}
        if sid:
            rec["sid"] = sid
        rec.update(f)
        out.append(rec)
    return out


def backfill(mdir, streams_dir, claude_dirs, her_cwds, chain_names):
    state = _state_load(mdir)
    seen = _seen_sids(mdir)
    added = skipped = 0

    # 1. The surviving archived streams. Their first line names the session.
    try:
        names = sorted(os.listdir(streams_dir))
    except OSError:
        names = []
    for n in names:
        if not n.endswith(".jsonl"):
            continue
        path = os.path.join(streams_dir, n)
        if _already(state, path):
            skipped += 1
            continue
        events = _events(path)
        kind, approx = _stream_kind(events)
        recs = parse_stream(path, kind, chain_names=chain_names,
                            src="stream-archive")
        if approx:
            for r in recs:
                r["approx"] = True
        recs = [r for r in recs if r.get("sid") not in seen or not r.get("sid")]
        for r in recs:
            if r.get("sid"):
                seen.add(r["sid"])
        append_records(mdir, recs)
        _mark(state, path)
        added += len(recs)

    # 2. Her own transcript directories, and only hers (spec rule 18).
    cwd_kinds = []
    for cwd in her_cwds:
        kind = "turn"
        if cwd.endswith("deskcrab-classify"):
            kind = "classify"
        elif cwd.endswith("deskcrab-chess-mover"):
            kind = "chess"
        cwd_kinds.append((cwd, kind))
    for cdir in claude_dirs:
        for cwd, kind in cwd_kinds:
            pdir = os.path.join(cdir, "projects", _slugify(cwd))
            try:
                files = sorted(os.listdir(pdir))
            except OSError:
                continue
            for n in files:
                if not n.endswith(".jsonl"):
                    continue
                path = os.path.join(pdir, n)
                if _already(state, path):
                    skipped += 1
                    continue
                recs = _transcript_records(path, kind)
                acct = account_name(
                    "" if cdir == os.path.expanduser("~/.claude") else cdir)
                for r in recs:
                    r["account"] = acct
                    r["account_n"] = account_number(acct, chain_names)
                recs = [r for r in recs
                        if not r.get("sid") or r["sid"] not in seen]
                for r in recs:
                    if r.get("sid"):
                        seen.add(r["sid"])
                append_records(mdir, recs)
                _mark(state, path)
                added += len(recs)
    _state_save(mdir, state)
    print("backfill: %d records added, %d sources already ingested"
          % (added, skipped))


# --------------------------------------------------------------------------
# Entry points.
# --------------------------------------------------------------------------

def record_from_args(a):
    chain = parse_chain(a.chain or os.environ.get(
        "CLAUDE_FALLBACK_CONFIG_DIR", ""))
    recs = parse_stream(a.stream, a.kind, model=a.model, effort=a.effort,
                        account_hint=a.account, chain_names=chain,
                        duration=a.duration, pid=a.pid)
    append_records(metrics_dir(a.dir), recs)


def record_result_object(doc, kind, model="", effort="", account="",
                         status="ok", duration=None, mdir=None):
    """For the Python callers: one `--output-format json` result object in,
    one appended record per model out. Same fail-safety as `record` — any
    trouble is swallowed (spec rule 6) — and the same switch (rule 16)."""
    if os.environ.get("TOKEN_LEDGER", "1") != "1":
        return
    try:
        chain = parse_chain(os.environ.get("CLAUDE_FALLBACK_CONFIG_DIR", ""))
        acct = account_name(account)
        base = {"ts": round(time.time(), 3), "kind": kind,
                "effort": effort or "", "account": acct,
                "account_n": account_number(acct, chain),
                "attempt": 1, "attempts": 1, "status": status,
                "src": "live", "pid": os.getpid()}
        if isinstance(doc, dict) and doc.get("session_id"):
            base["sid"] = doc["session_id"]
        recs = []
        mu = (doc or {}).get("modelUsage") \
            if isinstance(doc, dict) else None
        if isinstance(mu, dict) and mu:
            for mname, u in mu.items():
                rec = dict(base)
                rec["model"] = mname
                rec["input"] = int(u.get("inputTokens") or 0)
                rec["output"] = int(u.get("outputTokens") or 0)
                rec["cache_create"] = int(
                    u.get("cacheCreationInputTokens") or 0)
                rec["cache_read"] = int(u.get("cacheReadInputTokens") or 0)
                if u.get("costUSD") is not None:
                    rec["cost"] = round(float(u["costUSD"]), 6)
                recs.append(rec)
        elif isinstance(doc, dict) and isinstance(doc.get("usage"), dict):
            rec = dict(base)
            rec["model"] = model
            rec.update(_usage_fields(doc["usage"]))
            if doc.get("total_cost_usd") is not None:
                rec["cost"] = round(float(doc["total_cost_usd"]), 6)
            recs.append(rec)
        else:
            rec = dict(base)
            rec["model"] = model
            rec.update({"input": 0, "output": 0,
                        "cache_create": 0, "cache_read": 0})
            recs.append(rec)
        for rec in recs:
            if duration is not None:
                rec["duration"] = round(float(duration), 3)
            elif isinstance(doc, dict) and doc.get("duration_ms") is not None:
                rec["duration"] = round(doc["duration_ms"] / 1000.0, 3)
        append_records(metrics_dir(mdir), recs)
    except Exception:
        pass


def main(argv=None):
    p = argparse.ArgumentParser(prog="token_ledger")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record")
    r.add_argument("stream")
    r.add_argument("--kind", required=True)
    r.add_argument("--model", default="")
    r.add_argument("--effort", default="")
    r.add_argument("--account", default="")
    r.add_argument("--chain", default=None)
    r.add_argument("--duration", type=float, default=None)
    r.add_argument("--pid", type=int, default=None)
    r.add_argument("--dir", default=None)

    rp = sub.add_parser("report")
    rp.add_argument("date", nargs="?",
                    default=time.strftime("%Y-%m-%d"))
    rp.add_argument("--dir", default=None)

    ag = sub.add_parser("aggregate")
    ag.add_argument("--days", type=int, default=7)
    ag.add_argument("--dir", default=None)

    bf = sub.add_parser("backfill")
    bf.add_argument("--dir", default=None)
    bf.add_argument("--streams", default=None)
    bf.add_argument("--claude-dirs", default=None)
    bf.add_argument("--her-cwds", default=None)
    bf.add_argument("--chain", default=None)

    a = p.parse_args(argv)
    if a.cmd == "record":
        # Failure-safe by contract (spec rule 6): nothing on this path may
        # change the hosting run's outcome.
        try:
            record_from_args(a)
        except Exception:
            pass
        return 0
    if a.cmd == "report":
        report(metrics_dir(a.dir), a.date)
        return 0
    if a.cmd == "aggregate":
        json.dump(aggregate(metrics_dir(a.dir), a.days), sys.stdout,
                  separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    if a.cmd == "backfill":
        state = os.environ.get("XDG_STATE_HOME") \
            or os.path.expanduser("~/.local/state")
        streams = a.streams or os.path.join(state, "deskcrab", "streams")
        chain = parse_chain(a.chain if a.chain is not None
                            else os.environ.get(
                                "CLAUDE_FALLBACK_CONFIG_DIR", ""))
        backfill(metrics_dir(a.dir), streams, _claude_dirs(a.claude_dirs),
                 _her_cwds(a.her_cwds), chain)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
