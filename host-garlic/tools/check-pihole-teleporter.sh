#!/usr/bin/env bash
# Read-only check: which session type a password gets on a Pi-hole, and why
# GET /api/teleporter answers 403. Prints no secrets and saves nothing to disk.
# Usage (on zingy):  bash <(ssh serverus cat check-pihole-teleporter.sh) [url]
set -euo pipefail
URL=${1:-http://192.0.2.50:8082}

read -r -s -p "Pi-hole password for $URL: " PW; echo
BODY=$(printf '%s' "$PW" | python3 -c 'import sys,json; p=sys.stdin.read(); print(json.dumps({"password": p}))')
unset PW
R=$(curl -s -X POST "$URL/api/auth" -H 'Content-Type: application/json' --data-binary "$BODY")
unset BODY
python3 -c 'import sys,json; s=json.load(sys.stdin)["session"]; print("login valid:", s.get("valid"), "| message:", s.get("message"))' <<<"$R"
SID=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["session"].get("sid") or "")' <<<"$R")
unset R
[[ -n $SID ]] || { echo "no session, stopping"; exit 1; }

# Only the HTTP code and the JSON error message are printed; a successful
# export (a zip with password hashes) is discarded.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "sid: $SID" "$URL/api/teleporter")
echo "GET /api/teleporter: HTTP $CODE"
if [[ $CODE != 200 ]]; then
  curl -s -H "sid: $SID" "$URL/api/teleporter" | python3 -c 'import sys,json; e=json.load(sys.stdin).get("error",{}); print("error:", e.get("key"), "|", e.get("message"), "|", e.get("hint"))' || true
fi

curl -s -o /dev/null -X DELETE -H "sid: $SID" "$URL/api/auth"
echo "session closed"
