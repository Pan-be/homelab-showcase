#!/usr/bin/env bash
# Secret scan before every commit: gitleaks (in Docker) over the working tree and the whole
# history, plus a plain grep for long literal values next to secret-sounding keys.
# Exits non-zero on any finding. Findings are printed redacted.
set -uo pipefail
cd "$(dirname "$0")/.."
GITLEAKS=zricethezav/gitleaks:v8.30.1
failed=0

echo "==> gitleaks (working tree)"
docker run --rm -v "$PWD:/repo:ro" "$GITLEAKS" dir /repo --redact --no-banner || failed=1
if git rev-parse -q --verify HEAD >/dev/null; then
    echo "==> gitleaks (git history)"
    docker run --rm -v "$PWD:/repo:ro" "$GITLEAKS" git /repo --redact --no-banner || failed=1
fi

echo "==> literal values on secret-sounding keys"
# Only files git would take (tracked + new, not ignored), so local tooling such as .venv is skipped.
if git ls-files -z --cached --others --exclude-standard -- ':!*.example' \
    | xargs -0 -r grep -nIE \
    '(pass(word)?|secret|token|api[_-]?key|private[_-]?key)[A-Za-z_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/_.-]{12,}' \
    | grep -vE '\$\{|\{\{HOMEPAGE_VAR_|:/run/secrets/' | cut -d: -f1,2 | sed 's/$/: literal value (content not shown)/'; then
    failed=1
fi

((failed)) && { echo "scan FAILED"; exit 1; }
echo "scan OK"
