#!/usr/bin/env python3
"""The only supported creation door for durable conduct rules.

Similarity nominates an overlap; the caller must explicitly say distinct or
name the conduct rule being superseded.  Memory directives are in the same
preflight pool, so moving a sentence between drawers cannot multiply it.
"""

import argparse
import os
import re
import shutil
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
    args = ap.parse_args()

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

    os.makedirs(root, exist_ok=True)
    touched = [index, target] + ([old_path] if old_path else [])
    touch(*touched)
    body = f"# {args.title}\n\n{text}\n"
    if args.supersedes:
        body += f"\nSupersedes `{args.supersedes}`; its body is retained in archive.\n"
    tmp = target + f".tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, target)

    try:
        with open(index) as f:
            lines = f.readlines()
    except OSError:
        lines = ["# Conduct\n", "\n"]
    if args.supersedes:
        needle = f"`{args.supersedes}.md`"
        lines = [line for line in lines if needle not in line]
        archive = os.path.join(root, "archive")
        os.makedirs(archive, exist_ok=True)
        stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
        shutil.move(old_path, os.path.join(
            archive, f"{args.supersedes}-{stamp}.md"))
    gloss = f" — {args.gloss}" if args.gloss else ""
    lines.append(f"- **{args.title}**{gloss} → `{args.slug}.md`\n")
    itmp = index + f".tmp.{os.getpid()}"
    with open(itmp, "w") as f:
        f.writelines(lines)
    os.replace(itmp, index)
    if args.distinct or args.supersedes:
        store.resolve_rule_overlap(
            text, "superseded" if args.supersedes else "distinct", args.slug)
    print(f"added conduct:{args.slug}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
