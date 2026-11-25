#!/usr/bin/env bash
# Build the public showcase tree (homelab-showcase) from this private repo and a few tool repos.
#
#   scripts/showcase.sh [OUT_DIR]      default OUT_DIR: ~/dev/homelab-showcase
#
# Fail-closed: only files listed in showcase/manifest are copied, every text file goes through
# showcase/redact.sed, and the run aborts (OUT_DIR untouched) if anything in showcase/deny.regex
# or gitleaks matches the result. showcase/ itself (real values) is never exported.
# The output is a plain tree; its git history is separate and starts fresh.
set -euo pipefail
export LC_ALL=C.UTF-8

REPO=$(cd "$(dirname "$0")/.." && pwd)
CFG="$REPO/showcase"
OUT="${1:-$HOME/dev/homelab-showcase}"
GITLEAKS=$(command -v gitleaks || echo "$HOME/.local/bin/gitleaks")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

die() { echo "showcase: $*" >&2; exit 1; }
[ -x "$GITLEAKS" ] || die "gitleaks not found"

# 1. Copy the allowlist. Line: SRC<TAB>DST. SRC is relative to the repo, or ~/... / absolute.
#    A directory brings its git-tracked files (all files if it isn't a git work tree).
while IFS=$'\t' read -r src dst; do
  [[ -z "${src// }" || "$src" == \#* ]] && continue
  [ -n "${dst:-}" ] || die "manifest line without DST: $src"
  src="${src/#\~/$HOME}"; [[ "$src" == /* ]] || src="$REPO/$src"
  if [ -d "$src" ]; then
    if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      list=$(git -C "$src" ls-files)
    else
      list=$(cd "$src" && find . -type f | sed 's|^\./||')
    fi
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$src/$f" ] || continue   # tracked but deleted in the work tree
      mkdir -p "$STAGE/$dst/$(dirname "$f")"
      cp -p "$src/$f" "$STAGE/$dst/$f"
    done <<<"$list"
  elif [ -f "$src" ]; then
    mkdir -p "$STAGE/$(dirname "$dst")"
    cp -p "$src" "$STAGE/$dst"
  else
    die "manifest source missing: $src"
  fi
done <"$CFG/manifest"

# 2. Drop excluded paths (globs relative to the output root, one per line).
while IFS= read -r pat; do
  [[ -z "${pat// }" || "$pat" == \#* ]] && continue
  (cd "$STAGE" && shopt -s globstar nullglob && for p in $pat; do rm -rf -- "$p"; done)
done <"$CFG/exclude"

# 3. Showcase-only files (README, placeholders) go on top.
cp -a "$CFG/overlay/." "$STAGE/"

# 3b. Structural cuts (whole compose services, Homepage groups) from showcase/filter.py.
[ -f "$CFG/filter.py" ] && python3 -I "$CFG/filter.py" "$STAGE"

# 4. Redact every text file.
find "$STAGE" -type f -print0 | while IFS= read -r -d '' f; do
  grep -Iq . "$f" 2>/dev/null || continue          # binary or empty: left as is
  sed -E -i -f "$CFG/redact.sed" "$f"
done

# 5. Deny scan: print file:line only, never the matched text.
if hits=$(grep -rnIE -f "$CFG/deny.regex" "$STAGE" | cut -d: -f1,2 | sed "s|^$STAGE/||"); [ -n "$hits" ]; then
  echo "$hits" >&2
  die "deny patterns matched (above); fix redact.sed or the manifest. Nothing written."
fi
"$GITLEAKS" dir "$STAGE" --redact --no-banner --log-level warn \
  || die "gitleaks flagged the staged tree. Nothing written."

# 6. Sync into OUT (its .git is kept).
mkdir -p "$OUT"
rsync -a --delete --exclude .git "$STAGE/" "$OUT/"
echo "showcase: $(find "$STAGE" -type f | wc -l) files written to $OUT"
[ -d "$OUT/.git" ] || echo "showcase: $OUT has no git repo yet (git init -b main there)"
