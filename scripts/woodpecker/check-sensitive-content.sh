#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Pre-publish sensitive-content lint
# ----------------------------------------------------------------------------
# This repo is PUBLIC by design (clients/auditors should be able to see how the
# scanner works). The goal of this check is narrow: keep the public surface
# public-SAFE by blocking operational / identity / topology detail that is pure
# attacker reconnaissance and has zero transparency value. It does NOT lock the
# repo down — the conceptual architecture, tool list, scan profiles, safety
# system and ethics policy all stay public on purpose.
#
# It lints ADDED lines only (the diff), so pre-existing exposure does not block
# every commit — the historical cleanup is a separate, deliberate pass.
#
# Modes:
#   (default / "staged")   added lines in the staged diff      (pre-commit)
#   --range <A>..<B>        added lines in a commit range       (CI)
#   --all                   every tracked file                  (full audit; expect pre-existing hits)
#
# Escape hatch:  append  "# allow-sensitive: <reason>"  to a line to permit it.
# Specifics that must NOT be hard-coded in this PUBLIC file (internal GCP project
# names, client/engagement identifiers) live in an OPTIONAL gitignored file
# `.sensitive-extra-patterns` (one ERE per line, '#' comments ok). See the
# committed `.sensitive-extra-patterns.example`.
# ============================================================================

MODE="${1:-staged}"
RANGE=""
case "$MODE" in
  --range) RANGE="${2:?--range needs <A>..<B>}" ;;
  --all|staged|"") : ;;
  *) echo "usage: $0 [--range A..B | --all]"; exit 2 ;;
esac

# Generic patterns — safe to publish (they describe CLASSES of secret, not our
# specific names). Each is an extended-regex (grep -E).
PATTERNS=(
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.iam\.gserviceaccount\.com'  # GCP service-account emails
  '[A-Za-z0-9-]+\.peregrinetechsys\.(net|com)'                   # internal infra hostnames
  '(infra|peregrine-infrastructure)#[0-9]+'                      # internal cross-repo issue refs
  '10\.(1[0-9]{2}|[1-9]?[0-9])\.[0-9]{1,3}\.[0-9]{1,3}'          # private 10.0.0.0/8 IPs
  '192\.168\.[0-9]{1,3}\.[0-9]{1,3}'                             # private 192.168.0.0/16 IPs
  '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'          # private 172.16.0.0/12 IPs
  '[a-z0-9][a-z0-9-]*-pentest-reports'                           # internal GCS report buckets
)

# Files this check should never scan (it would match its own patterns / examples).
SELF_EXCLUDE_RE='(scripts/woodpecker/check-sensitive-content\.sh|\.sensitive-extra-patterns(\.example)?$|scripts/woodpecker/check-sensitive-content\.bats)'

# Load optional gitignored extra patterns (internal specifics kept out of this public file).
EXTRA_FILE=".sensitive-extra-patterns"
if [ -f "$EXTRA_FILE" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    PATTERNS+=("$line")
  done < "$EXTRA_FILE"
fi

# Build the combined regex.
COMBINED="$(IFS='|'; echo "${PATTERNS[*]}")"

# --- collect candidate lines as "path<TAB>content" -------------------------------
emit_added_lines() { # reads a `git diff` on stdin, emits path<TAB>addedline
  awk '
    /^\+\+\+ b\// { file=substr($0,7); next }
    /^\+/ && !/^\+\+\+/ { print file "\t" substr($0,2) }
  '
}

candidates() {
  case "$MODE" in
    --all)
      git ls-files | grep -vE "$SELF_EXCLUDE_RE" | while IFS= read -r f; do
        [ -f "$f" ] || continue
        grep -nE "$COMBINED" -- "$f" 2>/dev/null | sed "s|^|$f\t|" || true
      done
      ;;
    --range)
      git diff --no-color -U0 "$RANGE" | emit_added_lines | grep -vE "^($SELF_EXCLUDE_RE)\t"
      ;;
    *)
      git diff --cached --no-color -U0 | emit_added_lines | grep -vE "^($SELF_EXCLUDE_RE)\t"
      ;;
  esac
}

HITS=0
while IFS=$'\t' read -r path rest; do
  [ -z "${rest:-}" ] && continue
  case "$rest" in *"allow-sensitive"*) continue ;; esac
  if echo "$rest" | grep -qE "$COMBINED"; then
    match="$(echo "$rest" | grep -oE "$COMBINED" | head -1)"
    echo "  ✗ $path: $match"
    HITS=$((HITS + 1))
  fi
done < <(candidates)

if [ "$HITS" -gt 0 ]; then
  cat <<EOF

❌ Pre-publish lint: $HITS sensitive token(s) in added lines (this is a PUBLIC repo).
   Blocked classes: infra hostnames, service-account emails, private IPs, internal
   GCS buckets, internal cross-repo issue refs (+ any .sensitive-extra-patterns).
   Fix: remove/generalize the value, or — if genuinely safe to publish — append
   '# allow-sensitive: <reason>' to the line.
EOF
  exit 1
fi

echo "✅ Pre-publish lint: no sensitive tokens in $( [ "$MODE" = "--all" ] && echo "tracked files" || echo "added lines" )."
exit 0
