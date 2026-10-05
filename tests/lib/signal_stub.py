#!/usr/bin/env python3
"""A stand-in for `signal-cli daemon --socket --receive-mode manual` (specs/signal.md).

    signal_stub.py <socket> <dir>

Answers the JSON-RPC methods crab signal uses from canned state, appends every
request to <dir>/calls.jsonl, and pushes each envelope file dropped into
<dir>/push/ to every subscriber as a `receive` notification, in name order.
"""
import json
import os
import socket
import sys
import threading
import time

SOCK, DIR = sys.argv[1], sys.argv[2]
PUSH = os.path.join(DIR, "push")
os.makedirs(PUSH, exist_ok=True)
ACCOUNT = "+15550000001"
CONTACTS = [
    {"number": "+15550000002", "uuid": "11111111-1111-4111-8111-111111111111", "name": "Alex",
     "givenName": "Alex", "isHidden": False, "isBlocked": False, "note": "plays chess"},
    {"number": "+15550000003", "uuid": "22222222-2222-4222-8222-222222222222", "name": "Alexis",
     "givenName": "Alexis", "isHidden": False, "isBlocked": False},
    {"number": "+15550000004", "uuid": "33333333-3333-4333-8333-333333333333", "name": None,
     "isHidden": False, "isBlocked": False},
]
GROUPS = [{"id": "R1JPVVAx", "name": "Book Club", "isMember": True,
           "members": [{"number": "+15550000002", "uuid": CONTACTS[0]["uuid"]}],
           "pendingMembers": [], "groupInviteLink": None}]
subs = []
lock = threading.Lock()


def answer(req):
    m, p = req.get("method"), req.get("params") or {}
    if m == "listAccounts":
        return [{"number": ACCOUNT}]
    if m in ("subscribeReceive",):
        return 0
    if m != "listAccounts" and m not in ("register", "verify") and p.get("account") != ACCOUNT:
        raise ValueError("Method requires valid account parameter")
    if m == "listContacts":
        return CONTACTS if p.get("allRecipients") else [c for c in CONTACTS if c.get("name")]
    if m == "listGroups":
        return GROUPS
    if m == "send":
        return {"timestamp": 1700000000999, "results": [{"type": "SUCCESS"}]}
    if m in ("updateContact", "removeContact", "updateGroup", "quitGroup", "joinGroup",
             "updateProfile", "sendReaction"):
        return {"timestamp": 1700000000500}
    raise ValueError(f"stub has no method {m}")


def serve(conn):
    f = conn.makefile("rwb")
    for line in f:
        req = json.loads(line)
        with open(os.path.join(DIR, "calls.jsonl"), "a") as log:
            log.write(json.dumps(req) + "\n")
        try:
            resp = {"jsonrpc": "2.0", "result": answer(req), "id": req.get("id")}
        except ValueError as e:
            resp = {"jsonrpc": "2.0", "error": {"code": -32602, "message": str(e)}, "id": req.get("id")}
        with lock:
            f.write((json.dumps(resp) + "\n").encode())
            f.flush()
            if req.get("method") == "subscribeReceive":
                subs.append(f)


def pusher():
    while True:
        for name in sorted(os.listdir(PUSH)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(PUSH, name)
            env = json.load(open(path))
            os.remove(path)
            note = {"jsonrpc": "2.0", "method": "receive",
                    "params": {"subscription": 0, "result": {"envelope": env, "account": ACCOUNT}}}
            with lock:
                for f in list(subs):
                    try:
                        f.write((json.dumps(note) + "\n").encode())
                        f.flush()
                    except OSError:
                        subs.remove(f)
        time.sleep(0.05)


threading.Thread(target=pusher, daemon=True).start()
srv = socket.socket(socket.AF_UNIX)
srv.bind(SOCK)
srv.listen()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
