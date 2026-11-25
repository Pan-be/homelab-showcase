#!/usr/bin/env python3
"""Turn a `claude -p --output-format stream-json` run into the readable log: final report, denied tool calls, stats."""
import json
import sys

res = None
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "result":
        res = ev
if not res:
    print("(no result event)")
    sys.exit(0)
print(res.get("result") or "(empty result)")
denials = res.get("permission_denials") or []
print(f"--- permission denials: {len(denials)}")
for d in denials:
    print("  ", d.get("tool_name"), json.dumps(d.get("tool_input"), ensure_ascii=False)[:200])
secs = round((res.get("duration_ms") or 0) / 1000)
print(f"--- turns {res.get('num_turns')}, {secs} s, error={res.get('is_error')}")
