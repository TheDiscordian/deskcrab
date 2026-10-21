#!/usr/bin/env python3
"""The only supported creation door for durable conduct rules.

Similarity nominates an overlap; the caller must explicitly say distinct or
name the conduct rule being superseded.  Memory directives are in the same
preflight pool, so moving a sentence between drawers cannot multiply it.
"""

import argparse
import fcntl
import os
import re
import subprocess
import sys
from datetime import datetime

from memory import Store, default_dir


def conduct_dir():
    return os.environ.get("DESKCRAB_CONDUCT_DIR") or os.path.expanduser(
        "~/.local/share/deskcrab/conduct")


def touch(*paths):
    crab = os.path.expanduser("~/.local/bin/crab")
    subprocess.run([crab, "touching", *paths], check=True,
                   stdout=subprocess.DEVNULL)


def drawer_lock(root):
    """One lock over the whole filing transaction, add and retire alike, so two
    writers can never read the same index and each drop the other's line. The
    lock file lives in the state directory, outside the watched drawer, so
    taking it never reads to her watcher as another hand's write."""
    os.makedirs(root, exist_ok=True)
    state = os.path.join(os.environ.get("XDG_STATE_HOME")
                         or os.path.expanduser("~/.local/state"), "deskcrab")
    os.makedirs(state, exist_ok=True)
    fd = os.open(os.path.join(state, "conduct.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def read_index(index, verb):
    """The index as lines; None when there is none yet. Any other read fault
    refuses before anything is written, never treated as an empty index."""
    try:
        with open(index) as f:
            return f.readlines()
    except FileNotFoundError:
        return None
    except OSError as e:
        sys.exit(f"conduct {verb}: cannot read {index}: {e}")


def reserve_archive(root, slug):
    """An archive path for this slug that no other body holds, reserved with
    O_EXCL, so a slug retired or superseded twice in one second never
    overwrites the body archived the first time."""
    archive = os.path.join(root, "archive")
    os.makedirs(archive, exist_ok=True)
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    n = 1
    while True:
        name = f"{slug}-{stamp}.md" if n == 1 else f"{slug}-{stamp}-{n}.md"
        dest = os.path.join(archive, name)
        try:
            os.close(os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644))
            return dest
        except FileExistsError:
            n += 1


def show_hits(hits):
    for hit in hits[:12]:
        print(f"{hit['similarity']:.3f} {hit['drawer']}:{hit['ref']}  "
              f"{hit['existing_clause'][:120]}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(prog="crab conduct")
    sub = ap.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check", help="clause-level preflight only")
    check.add_argument("text", nargs="+")
    add = sub.add_parser("add", help="preflight and create one conduct rule")
    add.add_argument("--slug", required=True)
    add.add_argument("--title", required=True)
    add.add_argument("--gloss", default="")
    route = add.add_mutually_exclusive_group()
    route.add_argument("--distinct", action="store_true")
    route.add_argument("--supersedes", metavar="SLUG")
    add.add_argument("text", nargs="+")
    retire = sub.add_parser(
        "retire", help="take one rule out of the active set, body to archive/")
    retire.add_argument("slug")
    retire.add_argument("why", nargs="+")
    args = ap.parse_args()

    if args.cmd == "retire":
        return retire_rule(args.slug, " ".join(args.why).strip())

    text = " ".join(args.text).strip()
    store = Store(default_dir())
    hits = store.rule_overlaps(text, conduct_dir())
    if args.cmd == "check":
        show_hits(hits)
        return 3 if hits else 0

    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.slug):
        sys.exit("conduct add: --slug must be lowercase words joined by hyphens")
    root = conduct_dir()
    index = os.path.join(root, "CONDUCT.md")
    target = os.path.join(root, args.slug + ".md")
    if os.path.exists(target):
        sys.exit(f"conduct add: {args.slug} already exists")
    if hits and not (args.distinct or args.supersedes):
        store.queue_rule_overlap(text, "conduct", args.slug, None, hits)
        show_hits(hits)
        print("held in pending-rule-overlaps.json; amend the existing rule, "
              "or rerun with --distinct or --supersedes SLUG", file=sys.stderr)
        return 3

    old_path = None
    if args.supersedes:
        old_path = os.path.join(root, args.supersedes + ".md")
        if not os.path.isfile(old_path):
            sys.exit(f"conduct add: {args.supersedes} is not an active rule")

    lock = drawer_lock(root)
    if os.path.exists(target):
        sys.exit(f"conduct add: {args.slug} already exists")
    if old_path and not os.path.isfile(old_path):
        sys.exit(f"conduct add: {args.supersedes} is not an active rule")
    lines = read_index(index, "add")
    if lines is None:
        lines = ["# Conduct\n", "\n"]
    touched = [index, target] + (
        [old_path, os.path.join(root, "archive")] if old_path else [])
    touch(*touched)
    body = f"# {args.title}\n\n{text}\n"
    if args.supersedes:
        body += f"\nSupersedes `{args.supersedes}`; its body is retained in archive.\n"
    tmp = target + f".tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, target)

    if args.supersedes:
        needle = f"`{args.supersedes}.md`"
        lines = [line for line in lines if needle not in line]
        os.replace(old_path, reserve_archive(root, args.supersedes))
    gloss = f" — {args.gloss}" if args.gloss else ""
    lines.append(f"- **{args.title}**{gloss} → `{args.slug}.md`\n")
    itmp = index + f".tmp.{os.getpid()}"
    with open(itmp, "w") as f:
        f.writelines(lines)
    os.replace(itmp, index)
    if args.distinct or args.supersedes:
        store.resolve_rule_overlap(
            text, "superseded" if args.supersedes else "distinct", args.slug)
    os.close(lock)
    print(f"added conduct:{args.slug}")
    return 0


def retire_rule(slug, why):
    """Rule 28a's other door: the index line and the body leave together, so
    a retired rule is never half-gone (an index line naming a missing body,
    or a body no line names). The body keeps its text and gains the reason,
    under archive/ beside the bodies --supersedes retires. Everything is read
    before anything is written: a read fault refuses with nothing touched."""
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
        sys.exit("conduct retire: the slug must be lowercase words joined by hyphens")
    if not why:
        sys.exit("conduct retire: say why the rule is retired")
    root = conduct_dir()
    index = os.path.join(root, "CONDUCT.md")
    target = os.path.join(root, slug + ".md")
    lock = drawer_lock(root)
    if not os.path.isfile(target):
        sys.exit(f"conduct retire: {slug} is not an active rule")
    try:
        with open(target) as f:
            body = f.read()
    except OSError as e:
        sys.exit(f"conduct retire: cannot read {target}: {e}")
    # No index: the body is archived and no index is made.
    lines = read_index(index, "retire")

    touch(index, target, os.path.join(root, "archive"))
    when = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")
    dest = reserve_archive(root, slug)
    with open(dest, "w") as f:
        f.write(body.rstrip("\n") + f"\n\nRetired {when}: {why}\n")
    if lines is not None:
        needle = f"`{slug}.md`"
        itmp = index + f".tmp.{os.getpid()}"
        with open(itmp, "w") as f:
            f.writelines(line for line in lines if needle not in line)
        os.replace(itmp, index)
    os.remove(target)
    os.close(lock)
    print(f"retired conduct:{slug}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
