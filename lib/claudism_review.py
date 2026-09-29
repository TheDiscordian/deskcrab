#!/usr/bin/env python3
"""The claudism review's three steps (specs/nightly.md rules 39-44), driven by
lib/claudism-review through CR_* environment variables:

  material  print the judge's prompt: the day, the flags, the persona sheet,
            the conduct drawer, the phrase-list entries whose replacements
            fired, and the records recall put in front of her
  plan      read the judge's answer, keep the edits that pass every guard,
            print the files they will touch (one per line)
  apply     copy those files aside, then make the edits
  show      print the planned edits (the dry run)

Between steps the work directory carries `shown.json` (what the judge was
shown, so no edit can reach anything else) and `plan.json`.
"""
import json
import os
import re
import shutil
import subprocess
import sys

E = os.environ
WORK = E.get("CR_WORK", "")
DISPLAY_RE = re.compile(r"(?m)^[ \t]*---DISPLAY---[ \t]*$")
WAKE_KINDS = ("wake", "quiet", "tidy")


def say(msg):
    print(f"claudism-review: {msg}", file=sys.stderr)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def rows(path):
    out = []
    for line in read(path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def clip(text, budget, what):
    raw = text.encode("utf-8")
    if len(raw) <= budget:
        return text
    say(f"{what} outgrew its budget — {len(raw)} bytes, cut to {budget}")
    return raw[:budget].decode("utf-8", errors="ignore") + "\n[... cut here ...]"


def entries(list_text):
    """The phrase list's entries: heading -> the entry's whole text."""
    out, head, buf = {}, None, []
    for line in list_text.splitlines():
        if line.startswith("## "):
            if head:
                out[head] = "\n".join(buf)
            head, buf = line[3:].strip(), [line]
        elif head:
            buf.append(line)
    if head:
        out[head] = "\n".join(buf)
    return out


def recall(turn):
    """The records recall would put in front of her for this turn: the wake's
    agenda for a wake, the user's words otherwise."""
    ids_out = os.path.join(WORK, "ids.json")
    try:
        os.remove(ids_out)
    except OSError:
        pass
    user = (turn.get("user") or "").strip()
    if turn.get("kind") in WAKE_KINDS:
        args = ["--wake", "--reason", user]
    else:
        args = ["--query", user]
    try:
        subprocess.run([E["CR_CRAB"], "memory", "recall-block", *args,
                        "--peek", "--ids-out", ids_out],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=120)
        with open(ids_out) as f:
            return json.load(f)
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def material():
    day = E["CR_DAY"]
    turns = [t for t in rows(E["CR_JFILE"]) if t.get("kind") != "job"]
    turns.sort(key=lambda t: t.get("epoch", 0))
    spoken = [t for t in turns
              if DISPLAY_RE.split(t.get("reply") or "", 1)[0].strip()]
    if not spoken:
        say(f"no reply of her own on {day} — nothing to review")
        return 0

    flags = [f for f in rows(E["CR_FLAGS"]) if f.get("use") != "mention"]
    flagged = {(f.get("epoch"), f.get("pid")) for f in flags}

    lines = []
    for t in turns:
        stamp = (t.get("time") or "")[11:16] or "??:??"
        mark = " [flagged]" if (t.get("epoch"), t.get("pid")) in flagged else ""
        lines.append(f"[{stamp} {t.get('kind', '?')}{mark}]")
        if t.get("user"):
            lines.append(f"  the user: {t['user'].strip()}")
        said = DISPLAY_RE.split(t.get("reply") or "", 1)[0].strip()
        if said:
            lines.append(f"  her, aloud: {said}")
        lines.append("")
    day_text = clip("\n".join(lines), int(E["CR_JOURNAL_BUDGET"]), "the day")

    flag_lines, swapped = [], set()
    for f in flags:
        stamp = (f.get("time") or "")[11:16]
        line = f"- {stamp} {f.get('kind', '?')}: \"{f.get('sentence', '')}\" — {f.get('note', '')}"
        if f.get("outcome"):
            line += f" (live check: {f['outcome']}"
            if f.get("after"):
                line += f", went out as \"{f['after']}\""
            line += ")"
        flag_lines.append(line)
        if f.get("outcome") == "table-swap":
            swapped.add(f.get("note", ""))
    list_entries = entries(read(E["CR_LIST"]))
    swap_text = "\n\n".join(body for head, body in list_entries.items()
                            if head in swapped)

    persona = read(E["CR_PERSONA"]) if E.get("CR_PERSONA") else ""
    conduct_dir = E["CR_CONDUCT"]
    conduct_files = []
    if os.path.isdir(conduct_dir):
        names = sorted(n for n in os.listdir(conduct_dir) if n.endswith(".md"))
        names.sort(key=lambda n: n != "CONDUCT.md")
        conduct_files = names
    conduct_text = clip("\n\n".join(
        f"--- conduct/{n} ---\n{read(os.path.join(conduct_dir, n))}"
        for n in conduct_files), int(E["CR_CONDUCT_BUDGET"]), "the conduct drawer")

    # Flagged turns first, then the rest, up to the cap.
    order = sorted(spoken, key=lambda t: (t.get("epoch"), t.get("pid")) not in flagged)
    records = {}
    for t in order[:int(E["CR_RECALL_TURNS"])]:
        for r in recall(t):
            if r.get("kind") in ("directive", "note", "episodic", "observation", "miss"):
                records.setdefault(r["id"], r)
    record_text = "\n".join(f"#{r['id']} [{r['kind']}] {r['text']}"
                            for r in sorted(records.values(), key=lambda r: r["id"]))

    with open(os.path.join(WORK, "shown.json"), "w") as f:
        json.dump({"records": {str(k): v["kind"] for k, v in records.items()},
                   "conduct": conduct_files,
                   "persona": bool(persona),
                   "list": bool(swap_text)}, f)

    print(PROMPT.format(
        name=E.get("CR_NAME") or "the assistant",
        day=day,
        day_text=day_text,
        flags="\n".join(flag_lines) or "(nothing was flagged today)",
        persona=persona or "(no persona sheet)",
        conduct=conduct_text or "(no conduct drawer)",
        records=record_text or "(recall returned nothing)",
        swaps=swap_text or "(no replacement line fired today)",
        max_edits=E["CR_MAX_EDITS"]))
    return 0


PROMPT = """You are the part of a person's sleep that looks after her voice. \
She is {name}, a voice assistant with a persona of her own (the persona \
sheet below). Her habit to break is the claudism: sounding like a generic AI \
assistant instead of herself — the status-report cadence, grading her own \
remark before he has heard it, vouching for herself, narrating her own \
bookkeeping, reciting counts as proof, therapeutic or corporate phrasing, \
apology-monotone. These are ways of talking, not single words.

A model writes in the register of what it reads. Your job tonight: find the \
moments in the day below where she slipped into that register, and find what \
in the material she carries — her memory records, her conduct files, her \
persona sheet — pulled her there. Then fix that material, so she reads less \
of the assistant's voice tomorrow. Typical causes: a record written about her \
in the third person or as procedure ("He wants her to..."), a conduct body \
that reads like a policy document or an incident report, a persona line that \
invites the move, a replacement line that swapped in something that reads \
badly. Her spoken lines are evidence only; you never rewrite them.

Most nights need no edit. NOTHING is a normal answer. Change only what you \
can tie to a slip in today's material, keep the meaning of every rule and \
fact you touch, and write in her voice: plain, hers, and in the person the \
surrounding text already uses — the persona sheet speaks to her as "you", \
her records and conduct files speak as "I".

Edits available, at most {max_edits}:
- {{"route": "memory-rewrite", "id": N, "text": "...", "why": "..."}}
  rewords record #N in her voice; same claim.
- {{"route": "memory-retire", "id": N, "why": "..."}}
  retires record #N when it only adds the assistant's voice and no fact.
Only directives and notes can be reworded or retired; the other kinds are \
shown so you can see what she read.
- {{"route": "file-edit", "file": "persona" | "conduct/<name>.md" | "phrase-list", \
"old": "exact text", "new": "replacement", "why": "..."}}
  replaces text that occurs exactly once in that file. In the phrase list \
only `- replace:` lines may be revised or removed (new text empty, or only \
`- replace:` lines); never add an entry.
Only record ids listed below, and only the files listed below, can be edited. \
Code-side instructions are out of reach; do not ask for them.

Answer in exactly one of these forms and nothing else:
NOTHING — <one line: what you saw>
or
EDITS
<a JSON array of edits>

=== THE DAY ({day}) — her replies' spoken halves beside the user's words ===
{day_text}

=== TODAY'S FLAGS — lines her phrase list caught (pointers, not verdicts) ===
{flags}

=== PHRASE-LIST ENTRIES WHOSE REPLACEMENTS FIRED TODAY ===
{swaps}

=== HER PERSONA SHEET ===
{persona}

=== HER CONDUCT DRAWER — titles in CONDUCT.md sit in every prompt; bodies are opened on demand ===
{conduct}

=== MEMORY RECORDS RECALL PUT IN FRONT OF HER TODAY ===
{records}
"""


def parse_answer(text):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^NOTHING([^A-Za-z0-9]|$)", line):
            return None, re.sub(r"^NOTHING[^A-Za-z0-9]*", "", line).strip()
        if re.match(r"^EDITS([^A-Za-z0-9]|$)", line):
            body = "\n".join(lines[i + 1:]).strip()
            body = re.sub(r"^```[a-z]*\n|\n```$", "", body).strip()
            return json.loads(body), ""
    raise ValueError("no verdict line")


def resolve(file):
    """The path an edit names, or None when it is not a file the review may
    touch (rule 41)."""
    shown = SHOWN
    if file == "persona":
        return E.get("CR_PERSONA") if shown["persona"] else None
    if file == "phrase-list":
        return E["CR_LIST"] if shown["list"] else None
    if file.startswith("conduct/"):
        name = file[len("conduct/"):]
        if name in shown["conduct"] and "/" not in name:
            return os.path.join(E["CR_CONDUCT"], name)
    return None


def replace_lines_only(text):
    return all(line.strip().startswith("- replace:")
               for line in text.splitlines() if line.strip())


def check(edit, pending):
    """None when the edit may run, else why it may not."""
    route = edit.get("route")
    if route in ("memory-rewrite", "memory-retire"):
        rid = str(edit.get("id", ""))
        kind = SHOWN["records"].get(rid)
        if kind is None:
            return f"record #{rid} was not shown tonight"
        if kind not in ("directive", "note"):
            return f"record #{rid} is {kind}; only directives and notes are edited"
        if route == "memory-rewrite" and not (edit.get("text") or "").strip():
            return "no new text"
        return None
    if route == "file-edit":
        path = resolve(edit.get("file", ""))
        if not path:
            return f"'{edit.get('file')}' is not a file the review may edit"
        old, new = edit.get("old") or "", edit.get("new", "")
        if not old:
            return "no old text"
        if edit.get("file") == "phrase-list" and not (
                replace_lines_only(old) and replace_lines_only(new)):
            return "the phrase list takes only `- replace:` line changes"
        text = pending.get(path, read(path))
        n = text.count(old)
        if n != 1:
            return f"the old text occurs {n} times in {edit['file']}, not once"
        pending[path] = text.replace(old, new, 1)
        return None
    return f"unknown route '{route}'"


def plan():
    try:
        edits, why = parse_answer(read(os.path.join(WORK, "answer.txt")))
    except (ValueError, json.JSONDecodeError) as exc:
        say(f"the answer could not be read ({exc}) — nothing is changed")
        return 1
    if edits is None:
        say(f"nothing to change — {why}")
        return 1
    if not isinstance(edits, list):
        say("the EDITS body is not a list — nothing is changed")
        return 1
    cap = int(E["CR_MAX_EDITS"])
    keep, pending, files = [], {}, []
    for n, edit in enumerate(edits, 1):
        if not isinstance(edit, dict):
            say(f"edit {n} is not an object — refused")
            continue
        if len(keep) >= cap:
            say(f"over the cap of {cap} — not applied: "
                f"{edit.get('route')} {edit.get('id', edit.get('file', ''))} — {edit.get('why', '')}")
            continue
        refusal = check(edit, pending)
        if refusal:
            say(f"refused {edit.get('route')} "
                  f"{edit.get('id', edit.get('file', ''))} — {refusal}")
            continue
        keep.append(edit)
        if edit["route"] == "file-edit":
            path = resolve(edit["file"])
            if path not in files:
                files.append(path)
    with open(os.path.join(WORK, "plan.json"), "w") as f:
        json.dump({"edits": keep, "files": files}, f)
    if not keep:
        say("no edit survived its checks — nothing is changed")
        return 1
    for path in files:
        sys.stdout.write(path + "\n")
    return 0


def apply():
    with open(os.path.join(WORK, "plan.json")) as f:
        p = json.load(f)
    backup = E["CR_BACKUP"]
    for path in p["files"]:
        os.makedirs(backup, exist_ok=True)
        dest = os.path.join(backup, os.path.basename(path))
        if not os.path.exists(dest):
            shutil.copy2(path, dest)
    applied = 0
    for edit in p["edits"]:
        route, why = edit["route"], edit.get("why", "")
        if route == "file-edit":
            path = resolve(edit["file"])
            text = read(path)
            if text.count(edit["old"]) != 1:
                print(f"claudism-review: refused file-edit {edit['file']} — "
                      "the old text no longer occurs exactly once")
                continue
            tmp = path + ".claudism-review.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text.replace(edit["old"], edit.get("new", ""), 1))
            os.replace(tmp, path)
            print(f"claudism-review: edited {edit['file']} — {why}")
            applied += 1
            continue
        cmd = [E["CR_CRAB"], "memory"]
        if route == "memory-rewrite":
            cmd += ["rewrite", str(edit["id"]), edit["text"]]
        else:
            cmd += ["forget", str(edit["id"])]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            print(f"claudism-review: {route} #{edit['id']} "
                  f"({r.stdout.strip()}) — {why}")
            applied += 1
        else:
            print(f"claudism-review: {route} #{edit['id']} failed — "
                  f"{(r.stderr or r.stdout).strip()}")
    if p["files"]:
        print(f"claudism-review: the files as they were before tonight are in {backup}")
    print(f"claudism-review: {applied} edit(s) made")
    return 0


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else ""
    if step == "material":
        sys.exit(material())
    SHOWN = json.load(open(os.path.join(WORK, "shown.json")))
    if step == "plan":
        sys.exit(plan())
    if step == "apply":
        sys.exit(apply())
    if step == "show":
        for edit in json.load(open(os.path.join(WORK, "plan.json")))["edits"]:
            print("claudism-review: would " + json.dumps(edit, ensure_ascii=False))
        sys.exit(0)
    sys.exit("usage: claudism_review.py material|plan|apply")
