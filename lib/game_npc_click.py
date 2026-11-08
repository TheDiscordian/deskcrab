#!/usr/bin/env python3
"""game_npc_click.py — one deliberate click, aimed from the latest frame.

specs/game-npc-click.md is the contract. An intent — an NPC name from the
player's own visual registry, a built-in spec, or a literal R,G,B[:tol] —
becomes at most one pointer click on the private headless display, verified
against a frame grabbed AFTER the pointer came to rest on the target, with
bounded reacquisition when the target walks. No model call anywhere inside;
the only xte verbs ever emitted are mousemove and mouseclick.

Stdlib only. Frames come from ImageMagick `import` as 8-bit binary PPM over a
pipe; input goes out through `xte`. Both are resolved from PATH so a test can
stand shims in front of them.
"""

import argparse
import json
import os
import subprocess
import sys
import time

# The game viewport and the top-right toolbar strip inside the 1024x768
# client frame, as measured by the headless harness's hunter.
DEFAULT_VIEW = (258, 212, 766, 536)
DEFAULT_TOOLBAR = (568, 212, 766, 248)

BUILTINS = {
    'red-cape': lambda r, g, b: r > 150 and g < 30 and b < 30,
    'skin': lambda r, g, b: 200 < r < 255 and 120 < g < 190 and 60 < b < 140,
}

STATE_FRESH_MS = 2000
COMMAND_TIMEOUT_S = 5

EXIT_CLICKED = 0
EXIT_UNSTABLE = 2
EXIT_NO_TARGET = 3
EXIT_NOT_VISIBLE = 4
EXIT_USAGE = 5
EXIT_DISPLAY = 6
EXIT_HELD = 7
EXIT_BUSY = 8


class Usage(Exception):
    """A configuration or invocation error; exits 5."""


# --- intent -----------------------------------------------------------------

def parse_rgb_spec(text):
    """'R,G,B[:tol]' -> predicate, or None if the text is not that shape."""
    tol = 30
    body = text
    if ':' in body:
        body, _, tail = body.rpartition(':')
        if not tail.isdigit():
            return None
        tol = int(tail)
    parts = body.split(',')
    if len(parts) != 3 or not all(p.strip().lstrip('-').isdigit() for p in parts):
        return None
    r0, g0, b0 = (int(p) for p in parts)
    if not all(0 <= value <= 255 for value in (r0, g0, b0, tol)):
        return None
    return lambda r, g, b: (abs(r - r0) <= tol and abs(g - g0) <= tol
                            and abs(b - b0) <= tol)


def spec_predicate(spec_text):
    """A registry/CLI spec: built-in name or literal RGB. None if neither."""
    if spec_text in BUILTINS:
        return BUILTINS[spec_text]
    return parse_rgb_spec(spec_text)


def load_registry(path):
    """npc-visuals.conf -> {lowercase name: {spec, button, min}}.

    Flat lines `name = spec [button=N] [min=PIXELS]`; '#' and blank lines
    ignored; any other token is a load error — a typo must not silently
    become a default (spec rule 5).
    """
    entries = {}
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return entries
    for lineno, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            raise Usage("%s:%d: not a 'name = spec' line" % (path, lineno))
        name, _, rhs = line.partition('=')
        name = name.strip().lower()
        tokens = rhs.split()
        if not name or not tokens:
            raise Usage("%s:%d: empty name or spec" % (path, lineno))
        entry = {'spec': tokens[0], 'button': None, 'min': None}
        if spec_predicate(tokens[0]) is None:
            raise Usage("%s:%d: unknown spec %r" % (path, lineno, tokens[0]))
        for tok in tokens[1:]:
            key, eq, val = tok.partition('=')
            if key == 'button' and eq and val in ('1', '2', '3'):
                entry['button'] = int(val)
            elif key == 'min' and eq and val.isdigit() and int(val) > 0:
                entry['min'] = int(val)
            else:
                raise Usage("%s:%d: unknown token %r" % (path, lineno, tok))
        entries[name] = entry
    return entries


# --- frames -----------------------------------------------------------------

def parse_ppm(data):
    """Binary PPM (P6) -> (width, height, pixel getter (x, y) -> (r, g, b))."""
    pos = 0

    def token():
        nonlocal pos
        while pos < len(data):
            c = data[pos:pos + 1]
            if c.isspace():
                pos += 1
            elif c == b'#':
                while pos < len(data) and data[pos:pos + 1] != b'\n':
                    pos += 1
            else:
                break
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        return data[start:pos]

    if token() != b'P6':
        raise Usage('frame is not binary PPM')
    width, height, maxval = int(token()), int(token()), int(token())
    pos += 1                              # the single whitespace after maxval
    step = 2 if maxval > 255 else 1       # 16-bit samples ride high byte first
    raw = data[pos:]
    if len(raw) < width * height * 3 * step:
        raise Usage('frame truncated')

    def pixel(x, y):
        i = (y * width + x) * 3 * step
        return raw[i], raw[i + step], raw[i + 2 * step]

    return width, height, pixel


def find_blobs(width, height, pixel, pred, view, toolbar, min_pixels):
    """Connected matching blobs inside the viewport, largest first.

    Same shape as the harness hunter: 5x5-neighbourhood connectivity so a
    sprite split by antialiasing still reads as one body; blobs under
    min_pixels are specks and ignored.
    """
    x0, y0, x1, y1 = view
    tx0, ty0, tx1, ty1 = toolbar
    x1 = min(x1, width)
    y1 = min(y1, height)
    hits = set()
    for x in range(max(0, x0), x1):
        for y in range(max(0, y0), y1):
            if tx0 <= x < tx1 and ty0 <= y < ty1:
                continue
            r, g, b = pixel(x, y)
            if pred(r, g, b):
                hits.add((x, y))
    out = []
    while hits:
        seed = hits.pop()
        stack, blob = [seed], [seed]
        while stack:
            cx, cy = stack.pop()
            for nx in range(cx - 2, cx + 3):
                for ny in range(cy - 2, cy + 3):
                    if (nx, ny) in hits:
                        hits.remove((nx, ny))
                        stack.append((nx, ny))
                        blob.append((nx, ny))
        if len(blob) >= min_pixels:
            xs = [p[0] for p in blob]
            ys = [p[1] for p in blob]
            out.append((sum(xs) // len(xs), sum(ys) // len(ys), len(blob)))
    out.sort(key=lambda t: -t[2])
    return out


def pick(cands, near, nth):
    """Spec rule 6: nearest to the hint, else the nth largest, else largest."""
    if not cands:
        return None
    if near is not None:
        return min(cands, key=lambda c: (c[0] - near[0]) ** 2 + (c[1] - near[1]) ** 2)
    if nth is not None:
        return cands[nth - 1] if nth <= len(cands) else None
    return cands[0]


def nearest_to(cands, point, max_jump):
    """The matching blob nearest a point, or None beyond max_jump."""
    if not cands:
        return None
    best = min(cands, key=lambda c: (c[0] - point[0]) ** 2 + (c[1] - point[1]) ** 2)
    d2 = (best[0] - point[0]) ** 2 + (best[1] - point[1]) ** 2
    return best if d2 <= max_jump * max_jump else None


# --- presence gate ----------------------------------------------------------

def presence(state_dir, name, now_ms=None):
    """'ok' | 'not-visible' | 'skipped' per spec rule 7."""
    try:
        with open(os.path.join(state_dir, 'state.json')) as fh:
            snap = json.load(fh)
    except (OSError, ValueError):
        return 'skipped'
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    if not isinstance(snap, dict) or 'npcs' not in snap:
        return 'skipped'
    try:
        age = now_ms - int(snap.get('ts', 0))
    except (TypeError, ValueError):
        return 'skipped'
    if not snap.get('logged_in') or age < 0 or age > STATE_FRESH_MS:
        return 'skipped'
    wanted = name.casefold()
    for npc in snap.get('npcs') or []:
        if isinstance(npc, dict) \
                and str(npc.get('name') or '').casefold() == wanted:
            return 'ok'
    return 'not-visible'


# --- the display ------------------------------------------------------------

class Display:
    """The two doors to the private display; both patchable in tests."""

    def __init__(self, number):
        self.env = dict(os.environ, DISPLAY=':%s' % number)

    def grab(self):
        out = subprocess.run(
            ['import', '-depth', '8', '-window', 'root', '-silent', 'ppm:-'],
            env=self.env, stdout=subprocess.PIPE, check=True,
            timeout=COMMAND_TIMEOUT_S)
        return parse_ppm(out.stdout)

    def xte(self, *commands):
        subprocess.run(['xte'] + list(commands), env=self.env, check=True,
                       timeout=COMMAND_TIMEOUT_S)


# --- the run ----------------------------------------------------------------

def report(verdict, **fields):
    parts = [verdict]
    for key, val in fields.items():
        if val is not None:
            parts.append('%s=%s' % (key, val))
    print(' '.join(parts))


def run(args, display):
    gate = 'off' if args.no_presence_gate else 'skipped'
    if os.path.exists(os.path.join(args.state_dir, 'hold')):
        report('held', intent=args.intent, gate=gate)
        return EXIT_HELD
    if os.path.exists(os.path.join(args.state_dir, 'action.json')):
        report('busy', intent=args.intent, gate=gate)
        return EXIT_BUSY

    registry = load_registry(args.conf)
    entry = registry.get(args.intent.lower())
    if entry is not None:
        pred = spec_predicate(entry['spec'])
        button = args.button if args.button is not None else (entry['button'] or 1)
        min_pixels = args.min_pixels if args.min_pixels is not None \
            else (entry['min'] or 12)
        is_name = True
    else:
        pred = spec_predicate(args.intent)
        if pred is None:
            raise Usage('unknown intent %r: not in the registry, not a '
                        'built-in, not R,G,B[:tol]' % args.intent)
        button = args.button if args.button is not None else 1
        min_pixels = args.min_pixels if args.min_pixels is not None else 12
        is_name = False

    if not args.no_presence_gate and is_name:
        gate = presence(args.state_dir, args.intent)
        if gate == 'not-visible':
            report('not-visible', intent=args.intent, gate='ok')
            return EXIT_NOT_VISIBLE

    view = args.view
    toolbar = args.toolbar
    settle = args.settle_ms / 1000.0

    def candidates():
        width, height, pixel = display.grab()
        return find_blobs(width, height, pixel, pred, view, toolbar, min_pixels)

    cands = candidates()                                # grab 1
    target = pick(cands, args.near, args.nth)
    if target is None:
        report('no-target', intent=args.intent, gate=gate)
        return EXIT_NO_TARGET

    if args.dry_run:
        time.sleep(settle)
        fresh = nearest_to(candidates(), (target[0], target[1]), args.max_jump)
        drift = None
        if fresh is not None:
            drift = round(((fresh[0] - target[0]) ** 2
                           + (fresh[1] - target[1]) ** 2) ** 0.5, 1)
            target = fresh
        report('dry-run', intent=args.intent, x=target[0], y=target[1],
               pixels=target[2], drift=drift,
               stable=1 if drift is not None and drift <= args.stable_px else 0,
               gate=gate)
        return EXIT_CLICKED

    display.xte('mousemove %d %d' % (target[0], target[1]))
    pointer = (target[0], target[1])
    last = target
    attempt = 0
    while attempt < args.retries:
        attempt += 1
        time.sleep(settle)
        fresh_candidates = candidates()                  # exactly 1 grab/attempt
        fresh = nearest_to(fresh_candidates, pointer, args.max_jump)
        if fresh is None:
            # It left the pointer's local neighbourhood. Reacquire from this
            # SAME fresh frame with the original choice rule; never spend a
            # hidden extra grab or keep waiting around stale coordinates.
            fresh = pick(fresh_candidates, args.near, args.nth)
            if fresh is None:
                if attempt >= args.retries:
                    break
                continue
        last = fresh
        drift = ((fresh[0] - pointer[0]) ** 2 + (fresh[1] - pointer[1]) ** 2) ** 0.5
        if drift <= args.stable_px:
            display.xte('mouseclick %d' % button)
            time.sleep(settle)
            report('clicked', intent=args.intent, x=pointer[0], y=pointer[1],
                   button=button, attempt=attempt, drift=round(drift, 1),
                   pixels=fresh[2], gate=gate)
            return EXIT_CLICKED
        if attempt >= args.retries:
            if args.chase:
                display.xte('mousemove %d %d' % (fresh[0], fresh[1]))
                time.sleep(settle)
                display.xte('mouseclick %d' % button)
                report('clicked', intent=args.intent, x=fresh[0], y=fresh[1],
                       button=button, attempt=attempt, drift=round(drift, 1),
                       pixels=fresh[2], chased=1, gate=gate)
                return EXIT_CLICKED
            break
        display.xte('mousemove %d %d' % (fresh[0], fresh[1]))
        pointer = (fresh[0], fresh[1])
    report('unstable', intent=args.intent, x=last[0], y=last[1],
           attempt=attempt, gate=gate)
    return EXIT_UNSTABLE


# --- CLI --------------------------------------------------------------------

def rect(text):
    parts = text.split(',')
    if len(parts) != 4:
        raise argparse.ArgumentTypeError('want x0,y0,x1,y1')
    return tuple(int(p) for p in parts)


def point(text):
    parts = text.split(',')
    if len(parts) != 2:
        raise argparse.ArgumentTypeError('want X,Y')
    return tuple(int(p) for p in parts)


def main(argv):
    game_dir = os.environ.get(
        'DESKCRAB_GAME_DIR',
        os.path.expanduser('~/.local/share/deskcrab/game'))
    ap = argparse.ArgumentParser(
        description='One deliberate click, aimed from the latest frame '
                    '(specs/game-npc-click.md).')
    ap.add_argument('intent', help='registry name, built-in spec, or R,G,B[:tol]')
    ap.add_argument('--display', required=True)
    ap.add_argument('--button', type=int, default=None)
    ap.add_argument('--near', type=point, default=None)
    ap.add_argument('--nth', type=int, default=None)
    ap.add_argument('--retries', type=int, default=5)
    ap.add_argument('--settle-ms', type=int, default=180)
    ap.add_argument('--stable-px', type=int, default=4)
    ap.add_argument('--max-jump', type=int, default=48)
    ap.add_argument('--min-pixels', type=int, default=None)
    ap.add_argument('--view', type=rect, default=DEFAULT_VIEW)
    ap.add_argument('--toolbar', type=rect, default=DEFAULT_TOOLBAR)
    ap.add_argument('--conf', default=os.path.join(game_dir, 'npc-visuals.conf'))
    ap.add_argument('--state-dir',
                    default=os.environ.get('DESKCRAB_GAME_STATE_DIR',
                                           '/tmp/deskcrab-game'))
    ap.add_argument('--chase', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--no-presence-gate', action='store_true')
    try:
        args = ap.parse_args(argv)
    except SystemExit as err:
        return 0 if err.code == 0 else EXIT_USAGE

    if not str(args.display).isdigit():
        print('game-npc-click: display must be a bare number', file=sys.stderr)
        return EXIT_USAGE
    display_number = int(args.display)
    if display_number in (0, 1) and \
            os.environ.get('DESKCRAB_NPC_CLICK_ANY_DISPLAY') != '1':
        print('game-npc-click: display :%s is the physical seat — refused'
              % args.display, file=sys.stderr)
        return EXIT_DISPLAY
    # X accepts leading zeroes for the same display number. Normalise after
    # the physical-seat gate so :00 can never evade the :0 refusal.
    args.display = str(display_number)

    if args.button is not None and args.button not in (1, 2, 3):
        print('game-npc-click: button must be 1, 2, or 3', file=sys.stderr)
        return EXIT_USAGE
    if args.nth is not None and args.nth < 1:
        print('game-npc-click: nth must be at least 1', file=sys.stderr)
        return EXIT_USAGE
    if not 1 <= args.retries <= 50:
        print('game-npc-click: retries must be between 1 and 50', file=sys.stderr)
        return EXIT_USAGE
    if not 0 <= args.settle_ms <= 5000:
        print('game-npc-click: settle-ms must be between 0 and 5000', file=sys.stderr)
        return EXIT_USAGE
    if args.stable_px < 0 or args.max_jump < 0:
        print('game-npc-click: stability distances must be non-negative',
              file=sys.stderr)
        return EXIT_USAGE
    if args.min_pixels is not None and args.min_pixels < 1:
        print('game-npc-click: min-pixels must be at least 1', file=sys.stderr)
        return EXIT_USAGE

    try:
        return run(args, Display(args.display))
    except Usage as err:
        print('game-npc-click: %s' % err, file=sys.stderr)
        return EXIT_USAGE
    except (OSError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as err:
        print('game-npc-click: %s' % err, file=sys.stderr)
        return EXIT_USAGE


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
