#!/usr/bin/env python3
"""The commits record: what actually landed in her repositories, as evidence.

Rule 43b's question is whether the thing EXISTS, never whether the announcing
turn ran a tool. For a claim like "committing my three paths only" the artefact
is not a file mtime — the files sit unchanged on disk after a commit, and the
named-files record cannot tell a commit from an edit that was never staged.
The artefact is the commit itself, in the repository's own log, and until this
record existed the judge could not see it at all: a true commit claim at 22:55
on 2026-09-02 (748fcc7, exactly the three paths named) was flagged UNKEPT with
every other record blank.

Mechanical and model-free, like the rest of the widening. Prints one line per
commit that landed in the window, newest last; prints a plain sentence when
nothing landed, and exits non-zero only when it could not look at all — the
caller presents an unreadable record AS unreadable, never as an acquittal.
"""

import os
import subprocess
import sys
import time

MAX_COMMITS = 24
MAX_FILES = 12
PER_REPO_TIMEOUT = 10.0
# Unit separator, deliberately NOT the record separator: str.splitlines()
# treats \x1e (and \x1c, \x1d) as line boundaries, so a header keyed on it is
# torn apart before it can ever be recognised — every commit read as nothing.
SEP = "\x1f"


def candidate_repos(project_dir):
    """The roots worth looking at: her own workdir, her code shelf, the game."""
    override = os.environ.get("DESKCRAB_COMMIT_REPOS")
    if override:
        return [p for p in override.split(":") if p.strip()]
    home = os.path.expanduser("~")
    roots = []
    if project_dir:
        roots.append(project_dir)
    for parent in (os.path.join(home, "Programming", "Claude"),
                   os.path.join(home, "Games", "OpenRSC")):
        try:
            for name in sorted(os.listdir(parent)):
                roots.append(os.path.join(parent, name))
        except OSError:
            continue
    seen, out = set(), []
    for r in roots:
        real = os.path.realpath(r)
        if real in seen:
            continue
        seen.add(real)
        if os.path.isdir(os.path.join(real, ".git")):
            out.append(real)
    return out


def repo_commits(repo, since, until):
    fmt = SEP.join(["%H", "%ct", "%an", "%s"])
    cmd = ["git", "-C", repo, "log", "--all", "--no-merges",
           "--since=@%d" % int(since), "--format=%s%s" % (SEP, fmt),
           "--name-only"]
    if until:
        cmd.insert(5, "--until=@%d" % int(until))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=PER_REPO_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    label = os.path.basename(repo)
    commits, cur = [], None
    for raw in proc.stdout.splitlines():
        if raw.startswith(SEP):
            parts = raw[len(SEP):].split(SEP)
            if len(parts) < 4:
                cur = None
                continue
            sha, ct, author, subject = parts[0], parts[1], parts[2], SEP.join(parts[3:])
            try:
                ts = int(ct)
            except ValueError:
                ts = 0
            cur = {"repo": label, "sha": sha[:7], "ts": ts,
                   "author": author, "subject": subject, "files": []}
            commits.append(cur)
        elif raw.strip() and cur is not None:
            cur["files"].append(raw.strip())
    return commits


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: promise_commits.py <since-epoch> "
                         "[until-epoch] [project-dir]\n")
        return 2
    try:
        since = float(sys.argv[1])
    except ValueError:
        return 2
    until = None
    if len(sys.argv) > 2 and sys.argv[2] not in ("", "-"):
        try:
            until = float(sys.argv[2])
        except ValueError:
            until = None
    project_dir = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("PROJECT_DIR", "")

    repos = candidate_repos(project_dir)
    if not repos:
        print("(no repository of hers could be found to read)")
        return 0

    all_commits, failed = [], []
    for repo in repos:
        got = repo_commits(repo, since, until)
        if got is None:
            failed.append(os.path.basename(repo))
            continue
        all_commits.extend(got)

    if not all_commits:
        note = "(no commit landed in any of her repositories in this window)"
        if failed:
            note += " — and %d repository(ies) could not be read: %s" % (
                len(failed), ", ".join(sorted(failed)[:6]))
        print(note)
        return 0

    all_commits.sort(key=lambda c: c["ts"])
    clipped = 0
    if len(all_commits) > MAX_COMMITS:
        clipped = len(all_commits) - MAX_COMMITS
        all_commits = all_commits[-MAX_COMMITS:]

    lines = []
    if clipped:
        lines.append("(…%d earlier commit(s) clipped)" % clipped)
    for c in all_commits:
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(c["ts"])) if c["ts"] else "?"
        files = c["files"]
        shown = files[:MAX_FILES]
        tail = "" if len(files) <= MAX_FILES else " (+%d more)" % (len(files) - MAX_FILES)
        file_text = ", ".join(shown) if shown else "no files"
        lines.append("- [%s, %s, %s by %s] %s — %d file(s): %s%s" % (
            when, c["repo"], c["sha"], c["author"], c["subject"],
            len(files), file_text, tail))
    if failed:
        lines.append("(%d repository(ies) could not be read: %s)" % (
            len(failed), ", ".join(sorted(failed)[:6])))
    text = "\n".join(lines)
    if len(text) > 12000:
        text = text[:12000] + "\n(…clipped at the section budget)"
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
