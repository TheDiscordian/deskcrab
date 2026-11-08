"""promise_paths — the one resolver of a path-shaped token against the roots.

The promise checker holds three path-resolving sections (the pre-judge path
acquittal, the live judge's named-files record, and the night sweep's stat of
the day's named paths), and until 2026-09-07 each of them resolved a bare
relative token by plain join only: `os.path.join(root, token)`.  A join lands
only when the drawer the token was named from sits DIRECTLY under a configured
root, and the writing drawers nest deeper — at 03:27 that night a real file two
directories under the Library root read "NOT found on disk" over its author's
own write in the same turn's tool stream, and a kept promise was accused.
The same fault had already been patched once at one level (2026-09-05, rule
32bc); hand-naming ever-deeper drawers as roots does not generalise.

So: one helper, shared by all three sections so they cannot drift apart
(specs/turn-pipeline.md rule 32bd).  The plain join stays the fast path, tried
over every root in the configured order first.  Only when no join lands and the
token holds a slash does a bounded walk under each root look for paths whose
trailing components equal the token exactly.  Ambiguity is never resolved
silently: two or more distinct matches are reported as found-in-multiple with
the candidates named, never silently taken as the first.  A token that
resolves nowhere is still missing, exactly as before — the search loosens
nothing.
"""

import os
import time

# Bounds on the fallback walk, and why these numbers:
#
# SEARCH_MAX_DEPTH   how many directory levels below a root the walk will
#                    enter.  The drawers this exists for sit two or three
#                    levels down (music/<piece>/<bar>); eight covers any sane
#                    nesting with room to spare while keeping a home-directory
#                    root from becoming a filesystem crawl.
# SEARCH_MAX_ENTRIES how many directory entries (files and dirs together) the
#                    walk may examine per root before giving up.  $HOME is a
#                    configured root, and an unbounded walk of it is exactly
#                    what rule 32bd forbids; twenty thousand entries is enough
#                    to enumerate any real writing root completely and small
#                    enough that a huge root costs tens of milliseconds, not
#                    minutes, on a turn someone is waiting for.
SEARCH_MAX_DEPTH = 8
SEARCH_MAX_ENTRIES = 20000

# How many candidates a found-in-multiple report names before eliding the
# rest — the line goes into a bounded evidence block, not a listing.
MULTIPLE_NAMED = 4


def _dirs_under(root):
    """Every directory below root, bounded.

    Breadth-first, depth-capped at SEARCH_MAX_DEPTH, giving up after
    SEARCH_MAX_ENTRIES entries examined.  Hidden directories are skipped
    (.git, .cache and their kind would eat the whole entry budget), and a
    directory reached through a symlink is never entered — the walk cannot
    loop and cannot wander out of the root.  An unreadable root or child is
    simply not descended.
    """
    found = []
    entries = 0
    frontier = [(root, 0)]
    while frontier:
        d, depth = frontier.pop(0)
        if depth >= SEARCH_MAX_DEPTH:
            continue
        try:
            with os.scandir(d) as it:
                children = sorted(it, key=lambda e: e.name)
        except OSError:
            continue
        for e in children:
            entries += 1
            if entries > SEARCH_MAX_ENTRIES:
                return found
            try:
                if not e.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            if e.name.startswith("."):
                continue
            found.append(e.path)
            frontier.append((e.path, depth + 1))
    return found


def _search(tok, roots, cache):
    """The bounded fallback: paths under any root whose tail equals tok.

    A path matches when it is <some directory under a root>/<tok> exactly.
    One physical file reached through overlapping roots (the data dir sits
    under $HOME) counts once, by resolved path.  A token that walks upward
    or aliases itself (`.` or `..` components, doubled slashes) is never
    searched.  cache maps root -> its bounded directory list, so a caller
    resolving many tokens walks each root once.
    """
    if any(p in ("", ".", "..") for p in tok.split("/")):
        return []
    hits, seen = [], set()
    for root in roots:
        if root not in cache:
            cache[root] = _dirs_under(root) if os.path.isdir(root) else []
        for d in cache[root]:
            cand = os.path.join(d, tok)
            try:
                st = os.stat(cand)
            except OSError:
                continue
            real = os.path.realpath(cand)
            if real in seen:
                continue
            seen.add(real)
            hits.append((cand, st))
    return _collapse_mirrors(hits)


def _collapse_mirrors(hits):
    """Drop each candidate that is another candidate's mirror.

    A mirror's path embeds the original's WHOLE absolute path — the
    self-change watcher's shadow copies under the data dir are exactly this
    shape (<data dir>/self-shadows/<absolute path of the watched file>) —
    and a shadow of a real artefact is not a second opinion about where it
    lives.  Without this, the real 2026-09-07 file plus its shadow read as
    found-in-two, and manufactured ambiguity blocks an honest acquittal.
    The test is directional (the mirror ends with the original, never the
    reverse), so genuine distinct matches are untouched.
    """
    paths = [p for p, _ in hits]
    return [(p, st) for p, st in hits
            if not any(o != p and p.endswith(o) for o in paths)]


def resolve(tok, roots, cache=None):
    """Resolve one token.  Returns (kind, hits).

    kind is one of:
      'direct'   — one or more plain joins landed; hits carries every one, in
                   root order.  Root order is rule 32bc's documented
                   precedence, so the caller may take the first (or the first
                   that passes its own freshness test) exactly as before.
      'search'   — no join landed; the bounded walk found exactly one place.
      'multiple' — the walk found two or more distinct places.  The caller
                   MUST NOT quietly take one: name them, or decline to acquit.
      'missing'  — nothing anywhere.
    hits is a list of (path, os.stat_result).
    """
    if cache is None:
        cache = {}
    if tok.startswith(("/", "~")):
        p = os.path.expanduser(tok)
        try:
            return "direct", [(p, os.stat(p))]
        except OSError:
            return "missing", []
    hits = []
    for r in roots:
        cand = os.path.join(r, tok)
        try:
            hits.append((cand, os.stat(cand)))
        except OSError:
            continue
    if hits:
        return "direct", hits
    if "/" not in tok:
        return "missing", []
    hits = _search(tok, roots, cache)
    if len(hits) == 1:
        return "search", hits
    if hits:
        return "multiple", hits
    return "missing", []


def _stamp(st):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))


def describe(tok, roots, cache=None):
    """The evidence line the judge and the sweep both read, one shape.

    Kept byte-identical to the pre-helper formats for the found and missing
    cases — the accusation-and-acquittal wording downstream prompts and tests
    key on — with one new shape for ambiguity.
    """
    kind, hits = resolve(tok, roots, cache)
    if kind == "missing":
        return "- %s — NOT found on disk" % tok
    if kind == "multiple":
        named = "; ".join(
            "%s (modified %s)" % (p, _stamp(st))
            for p, st in hits[:MULTIPLE_NAMED])
        if len(hits) > MULTIPLE_NAMED:
            named += "; …and %d more" % (len(hits) - MULTIPLE_NAMED)
        return ("- %s — found in MULTIPLE places, ambiguous, not resolved: %s"
                % (tok, named))
    p, st = hits[0]
    return "- %s — exists (%s), modified %s" % (tok, p, _stamp(st))
