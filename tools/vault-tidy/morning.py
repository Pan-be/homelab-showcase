#!/usr/bin/env python3
"""08:00 morning summary: one ntfy push with last night's media upkeep and vault tidy (incl. Pan-be).

Reads only local state, no model call:
  - media: the newest --apply record in ~/.local/state/media-maintenance/runs.jsonl (its push text);
  - vault tidy: the newest live run log in ~/.local/state/vault-tidy/runs/ (status + its SUMMARY block).
A run missing from the last night, or a failed one, is said so in the push and raises its priority.
The ntfy topic is read from ~/.config/media-maintenance/ntfy_topic and never printed.
Usage: morning.py [--dry]   (--dry prints the push instead of sending it)
"""
import datetime as dt
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HOME = Path.home()
MEDIA_RUNS = HOME / ".local/state/media-maintenance/runs.jsonl"
TIDY_RUNS = HOME / ".local/state/vault-tidy/runs"
TOPIC_FILE = HOME / ".config/media-maintenance/ntfy_topic"
NTFY_SERVER = "https://ntfy.sh"
LOG = HOME / ".local/state/vault-tidy/morning.log"
MAX_AGE = dt.timedelta(hours=14)  # a night run older than this didn't happen last night
MAX_BODY = 3800                   # ntfy turns bodies over 4096 bytes into attachments


def media_section(now):
    """(lines, problem): the newest nightly --apply run's push text."""
    try:
        records = [json.loads(line) for line in MEDIA_RUNS.read_text().splitlines() if line.strip()]
    except (OSError, ValueError) as e:
        return [f"Media: run log unreadable ({e.__class__.__name__})"], True
    nightly = [r for r in records if r.get("apply")]
    if not nightly:
        return ["Media: no nightly run on record"], True
    last = nightly[-1]
    at = dt.datetime.fromisoformat(last["at"])
    if now - at > MAX_AGE:
        return [f"Media: no run last night (last {at.astimezone():%d.%m %H:%M})"], True
    if "lines" not in last:  # record from before the push text was stored
        return [f"Media: ran {at.astimezone():%H:%M}, free {last.get('free_gb')} GB, errors {len(last.get('errors', []))}"], bool(last.get("errors"))
    return [last.get("title", "Media upkeep")] + [f"  {line}" for line in last["lines"]], bool(last.get("errors"))


def tidy_section(now):
    """(lines, problem): the newest live vault tidy run, its status and SUMMARY block."""
    logs = sorted((p for p in TIDY_RUNS.glob("*.log") if not p.name.endswith("-dry.log")),
                  key=lambda p: p.stat().st_mtime)
    if not logs:
        return ["Vault tidy: no run on record"], True
    log = logs[-1]
    if now - dt.datetime.fromtimestamp(log.stat().st_mtime, dt.timezone.utc) > MAX_AGE:
        return ["Vault tidy: no run last night"], True
    # one log file can hold more than one run (same start minute): judge only the last one
    text = re.split(r"^\[[^\]]+\] start \(", log.read_text(errors="replace"), flags=re.M)[-1]
    fail = re.findall(r"\] (?:FAIL|SKIP): (.*)", text)
    if fail:
        return [f"Vault tidy FAILED: {fail[-1][:150]}"], True
    match = re.search(r"^SUMMARY:\s*\n(.*?)(?:\n--- permission denials|\Z)", text, re.S | re.M)
    lines = [line.strip() for line in match.group(1).splitlines() if line.strip()][:8] if match else []
    pushed = re.search(r"committed and pushed (\w+)", text)
    head = "Vault tidy" + (f" (commit {pushed.group(1)})" if pushed else ", nothing to change" if "nothing to change" in text else "")
    return [head] + [f"  {line}" for line in lines or ["(no summary in the run log)"]], False


def main():
    dry = "--dry" in sys.argv
    now = dt.datetime.now(dt.timezone.utc)
    media, media_bad = media_section(now)
    tidy, tidy_bad = tidy_section(now)
    body = "\n".join(media + [""] + tidy)
    if len(body.encode()) > MAX_BODY:
        body = body.encode()[:MAX_BODY].decode(errors="ignore") + "\n(cut; full text in the run logs)"
    problem = media_bad or tidy_bad
    title = "Serverus: morning summary" + (" - check" if problem else "")
    if dry:
        print(title)
        print(body)
        return 0
    try:
        topic = TOPIC_FILE.read_text().strip()
        req = urllib.request.Request(f"{NTFY_SERVER}/{topic}", method="POST", data=body.encode(),
                                     headers={"Title": title, "Tags": "sunrise",
                                              "Priority": "high" if problem else "default"})
        urllib.request.urlopen(req, timeout=20).read()
        result = "sent"
    except (OSError, urllib.error.URLError) as e:
        result = f"failed: {e.__class__.__name__}"
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(json.dumps({"at": now.isoformat(timespec="seconds"), "title": title, "result": result,
                            "media_problem": media_bad, "tidy_problem": tidy_bad}) + "\n")
    print(title, result)
    return 0 if result == "sent" else 1


if __name__ == "__main__":
    sys.exit(main())
