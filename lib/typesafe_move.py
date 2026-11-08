#!/usr/bin/env python3
"""typesafe_move: one TypeSafe System One call — request in, answer out.

The chess mover's TypeSafe engine (specs/chessweb.md rule 16h). Jev is a
decision-only model: it generates no text, so the mover asks one Choice
question whose options ARE the legal moves and the answer is structurally
one of them. This helper is the transport and nothing else: the complete
request body (state, questions, model) arrives as JSON on stdin, one POST
goes to the evaluation endpoint, and the chosen option leaves on stdout as
the same ``{"result": ..., "usage": ...}`` object the Claude CLI's
``--output-format json`` hands back — so ``chess_mover._call`` reads every
engine with one parser and the token ledger records the attempt unchanged.

It runs as a subprocess ON PURPOSE: the mover's supersession kill and the
clock bound (rules 16c and 16g) land on a process, and a library call
inside the mover thread could not be killed mid-connect.

Stdlib only — one POST needs no SDK in the chess venv. The key is read
from TYPESAFE_API_KEY in the environment, never argv (argv is world-
readable in /proc). TYPESAFE_API_URL points tests at a local stub so no
test ever spends a live token.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = "https://api.typesafe.ai/v1/systemone"

# Transport-level, not a thinking ceiling: Jev answers a Choice in about a
# second, so a dead minute means a dead connection. The retired per-attempt
# thinking ceiling (chessweb.md rule 16g's ruling) is a different thing and
# stays retired — a timeout here is a failed attempt on the ordinary retry
# rounds, never a manufactured move.
def _timeout():
    try:
        return float(os.environ.get("TYPESAFE_HTTP_TIMEOUT", "60"))
    except ValueError:
        return 60.0


# Extra tries on 429/529 inside the one attempt — the provider's own
# back-off advice. Anything longer-lived is the mover's round machinery.
RETRIES = 2


def _fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _post(url, body, key, timeout):
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def main():
    argv = sys.argv[1:]
    model = None
    if "--model" in argv:
        try:
            model = argv[argv.index("--model") + 1]
        except IndexError:
            _fail("typesafe: --model given without a value")

    key = (os.environ.get("TYPESAFE_API_KEY") or "").strip()
    if not key:
        # "not logged in" on purpose: the mover's auth classifier and cause
        # extraction already speak that vocabulary (chessweb.md rule 16h).
        _fail("typesafe: TYPESAFE_API_KEY is not set — not logged in to "
              "TypeSafe, no call made")

    try:
        request = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as e:
        _fail(f"typesafe: request on stdin is not JSON: {e}")
    if not isinstance(request, dict):
        _fail("typesafe: request on stdin is not a JSON object")
    if model:
        request["model"] = model

    body = json.dumps(request, separators=(",", ":")).encode("utf-8")
    url = os.environ.get("TYPESAFE_API_URL") or DEFAULT_URL
    timeout = _timeout()

    doc = None
    for attempt in range(RETRIES + 1):
        try:
            doc = _post(url, body, key, timeout)
            break
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read(2000).decode("utf-8", "replace")
            except OSError:
                pass
            detail = " ".join(detail.split())[:200]
            if e.code in (429, 529) and attempt < RETRIES:
                delay = 1.0
                retry_after = (e.headers or {}).get("retry-after")
                if retry_after:
                    try:
                        delay = min(max(float(retry_after), 0.0), 5.0)
                    except ValueError:
                        pass
                time.sleep(delay)
                continue
            # The wording is the contract (rule 16h): each failure names its
            # cause in the mover's own marker vocabulary, so rule 16e's
            # cause extraction and the capacity/auth classifiers read a
            # TypeSafe failure like any other engine's.
            if e.code == 429:
                _fail(f"typesafe: rate limit (HTTP 429): {detail}")
            if e.code == 529:
                _fail(f"typesafe: overloaded (HTTP 529): {detail}")
            if e.code in (401, 403):
                _fail(f"typesafe: not logged in — the API key was refused "
                      f"(HTTP {e.code}): {detail}")
            _fail(f"typesafe: api error HTTP {e.code}: {detail}")
        except (urllib.error.URLError, OSError) as e:
            if attempt < RETRIES:
                time.sleep(1.0)
                continue
            _fail(f"typesafe: api error: connection failed: {e}")

    if not isinstance(doc, dict):
        _fail("typesafe: api error: response is not a JSON object")

    answers = doc.get("answers")
    answer = answers.get("move") if isinstance(answers, dict) else None
    if not isinstance(answer, dict):
        _fail("typesafe: api error: no `move` answer in the response: "
              + json.dumps(doc)[:200])
    choice = answer.get("choice")
    if not isinstance(choice, str) or not choice.strip():
        _fail("typesafe: api error: the `move` answer carries no choice: "
              + json.dumps(answer)[:200])

    out = {
        "result": choice.strip(),
        "model": doc.get("model") or request.get("model") or "",
        "usage": doc.get("usage") if isinstance(doc.get("usage"), dict)
        else {},
    }
    confidence = answer.get("confidence")
    if isinstance(confidence, (int, float)):
        out["confidence"] = confidence
    print(json.dumps(out))


if __name__ == "__main__":
    main()
