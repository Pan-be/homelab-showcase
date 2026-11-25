#!/usr/bin/env python3
"""Find which dns/misc keys garlic's Pi-hole rejects when nebula-sync copies them.

Reads the dns and misc sections from Serverus (primary, read-only there) and
PATCHes them into garlic (replica) one key at a time, the same way nebula-sync
does, printing the keys that fail with Pi-hole's own error message.
Keys that are accepted are applied on garlic (that is the sync's goal anyway).
Nothing on Serverus changes. Passwords are typed, never printed or saved.

Usage (on zingy):  python3 <(ssh serverus cat check-pihole-config-sync.py)
"""
import getpass
import json
import time
import urllib.error
import urllib.request

PRIMARY = "http://192.0.2.50:8082"
REPLICA = "http://192.0.2.51:8082"
SECTIONS = {"dns": {"listeningMode", "interface"}, "misc": set()}  # excluded keys as in the sync


def call(method, url, sid=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if sid:
        req.add_header("sid", sid)
    for attempt in range(15):  # FTL may restart after some config changes
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            if e.code in (502, 503) and attempt < 14:
                time.sleep(2)
                continue
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"raw": raw[:200].decode(errors="replace")}
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == 14:
                raise
            time.sleep(2)


PASSWORDS = {}


def login(base, label):
    if base not in PASSWORDS:
        PASSWORDS[base] = getpass.getpass(f"{label} Pi-hole password: ")
    code, r = call("POST", f"{base}/api/auth", body={"password": PASSWORDS[base]})
    s = r.get("session", {})
    if not s.get("valid"):
        raise SystemExit(f"{label}: login failed ({code}, {s.get('message')})")
    print(f"{label}: login OK ({s.get('message')})")
    return s["sid"]


def err_text(r):
    e = r.get("error", {}) if isinstance(r, dict) else {}
    return f"{e.get('message')} | {e.get('hint')}" if e else json.dumps(r)[:200]


p_sid = login(PRIMARY, "Serverus")
r_sid = login(REPLICA, "garlic")
failed = []
try:
    for section, excluded in SECTIONS.items():
        code, r = call("GET", f"{PRIMARY}/api/config/{section}", p_sid)
        if code != 200:
            raise SystemExit(f"GET {section} from Serverus: HTTP {code} {err_text(r)}")
        values = r["config"][section]
        ok = 0
        for key, value in values.items():
            if key in excluded:
                continue
            body = {"config": {section: {key: value}}}
            code, r = call("PATCH", f"{REPLICA}/api/config", r_sid, body)
            if code == 401:  # session lost after an FTL restart
                r_sid = login(REPLICA, "garlic")
                code, r = call("PATCH", f"{REPLICA}/api/config", r_sid, body)
            if code == 200:
                ok += 1
            else:
                failed.append(f"{section}.{key}")
                print(f"  REJECTED {section}.{key}: HTTP {code} | {err_text(r)}")
        print(f"{section}: {ok} keys accepted")
finally:
    for base, sid in ((PRIMARY, p_sid), (REPLICA, r_sid)):
        call("DELETE", f"{base}/api/auth", sid)
    PASSWORDS.clear()
    print("sessions closed")

print("rejected keys:", ", ".join(failed) if failed else "none")
