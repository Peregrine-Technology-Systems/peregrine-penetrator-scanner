#!/usr/bin/env bash
set -euo pipefail

# #850: reconstruct RELEASE_NOTES.md from a known-good released history + the
# live pending entries, repairing a merge=union MISFILE (entries pushed OUT of
# ## Unreleased INTO a versioned section by a staging→main merge with no cleanup).
#
# This is the "reconstruct beats dedup" move from ROBUST_PROMOTE_PATTERN.md. It
# is the OPPOSITE direction from cleanup-stale-unreleased.sh (which strips
# Unreleased entries that DUPLICATE a versioned one). Use this one only on the
# drift-failure path — when ## Unreleased is empty but content shipped — never on
# the happy path.
#
# It is deliberately keyed off origin/staging's LIVE ## Unreleased (the source of
# truth for "what is pending"), filtered against the last tag's released set:
#   pending_new = (staging ## Unreleased lines) − (last tag's versioned lines)
# Both filters are load-bearing:
#   - staging Unreleased → a retroactively-added HISTORICAL entry is not here, so
#     it is never touched (avoids the Pass-3 over-move sharp edge).
#   - − last tag's versioned → an entry that is in staging's Unreleased only
#     because sync-back has not cleared it yet, but is already released, stays put
#     (avoids yanking a just-released entry back out of its version section).
#
# Usage: reconstruct-release-notes.sh <target_notes> <last_tag_notes> <staging_notes>
#   target_notes    — RELEASE_NOTES.md to rewrite in place (main's, post-merge)
#   last_tag_notes   — RELEASE_NOTES.md from the last tag (clean versioned history)
#   staging_notes    — RELEASE_NOTES.md from origin/staging (live pending source)
#
# Exit codes:
#   0  reconstructed and rewrote target_notes
#   2  internal error (missing input, awk failure) — caller must NOT tag
#   3  no recoverable pending entries (staging Unreleased empty/all-released) —
#      caller must fall through to its own fail-loud (never guess a release)
#
# Side effect on exit 0: target_notes is rewritten. Prints a summary to stderr.

TARGET="${1:?target notes path required}"
LAST_TAG_NOTES="${2:?last-tag notes path required}"
STAGING_NOTES="${3:?staging notes path required}"

for f in "$TARGET" "$LAST_TAG_NOTES" "$STAGING_NOTES"; do
  [ -f "$f" ] || { echo "reconstruct: input not found: $f" >&2; exit 2; }
done

TMPDIR_RN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RN"' EXIT
RELEASED="${TMPDIR_RN}/released"
STAGING_UNREL="${TMPDIR_RN}/staging_unrel"
PENDING="${TMPDIR_RN}/pending"
VERSIONED="${TMPDIR_RN}/versioned"
OUT="${TMPDIR_RN}/out"

# released set: every non-blank line under any `## vN.M.P` section of the last tag
awk '
  /^## v[0-9]/ { inv = 1; next }
  /^## /       { inv = 0 }
  inv { sub(/[ \t]+$/, ""); if ($0 != "") print }
' "$LAST_TAG_NOTES" | sort -u > "$RELEASED"

# staging Unreleased: non-blank lines under `## Unreleased` (order-preserving)
awk '
  /^## Unreleased[[:space:]]*$/ { inu = 1; next }
  /^## /                        { inu = 0 }
  inu { sub(/[ \t]+$/, ""); if ($0 != "") print }
' "$STAGING_NOTES" > "$STAGING_UNREL"

# pending_new = staging Unreleased lines NOT already released (order preserved)
grep -Fxv -f "$RELEASED" "$STAGING_UNREL" > "$PENDING" || true

if [ ! -s "$PENDING" ]; then
  echo "reconstruct: no recoverable pending entries (staging Unreleased empty or all already released)" >&2
  exit 3
fi

# versioned history: the last tag's file from its first `## vN` header to EOF
awk '/^## v[0-9]/ { seen = 1 } seen' "$LAST_TAG_NOTES" > "$VERSIONED"
if [ ! -s "$VERSIONED" ]; then
  echo "reconstruct: last-tag notes have no versioned sections — refusing to rebuild" >&2
  exit 2
fi

{
  printf '# Release Notes\n\n## Unreleased\n\n'
  cat "$PENDING"
  printf '\n'
  cat "$VERSIONED"
} > "$OUT"

[ -s "$OUT" ] || { echo "reconstruct: assembled empty output — refusing to overwrite" >&2; exit 2; }

mv "$OUT" "$TARGET"
echo "reconstruct: restored $(wc -l < "$PENDING" | tr -d ' ') pending entry(ies) to ## Unreleased" >&2
exit 0
