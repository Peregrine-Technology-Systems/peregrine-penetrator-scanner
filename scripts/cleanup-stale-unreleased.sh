#!/usr/bin/env bash
set -euo pipefail

# Rule #13 / #1394: strip stale Unreleased entries already in a versioned section.
#
# merge=union on RELEASE_NOTES.md preserves identical lines from both branches.
# After version-bump on main moves entries from `## Unreleased` into `## vX.Y.Z`,
# the sync-back to development/staging brings the new versioned section over —
# but `merge=union` does NOT remove the stale duplicates that still live under
# `## Unreleased` on the source branches. The next promote merge sees:
#
#   ## Unreleased
#   - fix: X       ← stale, already in v0.4.42
#   - fix: NEW     ← genuinely new
#
#   ## v0.4.42
#   - fix: X
#
# `merge=union` aligns the stale "fix: X" lines with the versioned section AND
# folds "fix: NEW" in too. Result on main: empty `## Unreleased`, NEW entry
# misfiled under v0.4.42 — version-bump exits 0, no new tag.
#
# This script strips any line under `## Unreleased` that appears verbatim in
# any `## vN.M.P` section of the same file.
#
# Usage: cleanup-stale-unreleased.sh [path/to/RELEASE_NOTES.md]
#   Default path: RELEASE_NOTES.md (relative to PWD)
#
# Exit codes:
#   0  always (no-op if file missing or nothing to strip — never silent failure)
#   2  internal error (awk failed, file unwritable)
#
# Side effect: rewrites the target file in place. Prints a summary to stdout.
# Does NOT git-add or commit — caller decides.

FILE="${1:-RELEASE_NOTES.md}"

if [ ! -f "$FILE" ]; then
  echo "cleanup-stale-unreleased: file not found: $FILE (no-op)"
  exit 0
fi

TMP="${FILE}.cleanup.tmp"

# Two-pass awk:
#   Pass 1 — collect every non-blank line that appears under any `## vN.M.P`
#            section into `versioned[]`.
#   Pass 2 — emit every line, but skip any non-blank line under `## Unreleased`
#            that exists in `versioned[]`.
#
# Tracked stats are printed for human verification (no silent loss).
awk '
  BEGIN { in_versioned = 0; in_unreleased = 0; dropped = 0 }
  # Both passes share the file via NR==FNR + next.
  NR == FNR {
    if ($0 ~ /^## v[0-9]/)      { in_versioned = 1; next }
    else if ($0 ~ /^## /)       { in_versioned = 0 }
    if (in_versioned) {
      sub(/[ \t]+$/, "", $0)
      if ($0 != "") versioned[$0] = 1
    }
    next
  }
  # Pass 2 (second file pass): emit.
  {
    if      ($0 ~ /^## Unreleased/)   { in_unreleased = 1; print; next }
    else if ($0 ~ /^## /)             { in_unreleased = 0; print; next }
    if (in_unreleased) {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (line != "" && (line in versioned)) {
        dropped++
        next
      }
    }
    print
  }
  END {
    if (dropped > 0) {
      printf("cleanup-stale-unreleased: dropped %d stale Unreleased line(s) already in versioned sections\n", dropped) > "/dev/stderr"
    } else {
      print "cleanup-stale-unreleased: nothing to strip" > "/dev/stderr"
    }
  }
' "$FILE" "$FILE" > "$TMP"

if [ ! -s "$TMP" ]; then
  echo "cleanup-stale-unreleased: ERROR — awk produced empty output, refusing to overwrite $FILE" >&2
  rm -f "$TMP"
  exit 2
fi

mv "$TMP" "$FILE"
exit 0
