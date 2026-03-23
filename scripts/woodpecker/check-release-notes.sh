#!/usr/bin/env bash
set -euo pipefail

# Enforce RELEASE_NOTES.md update when code files change
# Also enforces that every entry under ## Unreleased references an issue number
# Required for SOC 2 Type II / ISO 27001 traceability

# Get files changed in this commit
CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD)

# Check if any non-doc files changed (whitelist doc extensions, everything else is code)
NON_DOC_FILES=$(echo "$CHANGED_FILES" | grep -vE '\.(md|txt|pdf|docx|xlsx|csv|png|jpg|svg|gif|ico)$' || true)

if [ -z "$NON_DOC_FILES" ]; then
  echo "Docs-only change — RELEASE_NOTES check skipped"
  exit 0
fi

# Check if RELEASE_NOTES.md was updated
if ! echo "$CHANGED_FILES" | grep -q 'RELEASE_NOTES.md'; then
  echo "ERROR: Code files changed but RELEASE_NOTES.md was not updated."
  echo ""
  echo "Changed code files:"
  echo "$NON_DOC_FILES" | sed 's/^/  /'
  echo ""
  echo "Add a line under '## Unreleased' in RELEASE_NOTES.md describing your change."
  exit 1
fi

echo "RELEASE_NOTES.md updated — checking issue references..."

# Check that all entries under ## Unreleased reference an issue
# Extract lines between ## Unreleased and the next ## header
UNRELEASED=$(sed -n '/^## Unreleased$/,/^## /{/^## /!p}' RELEASE_NOTES.md | grep '^- ' || true)

if [ -z "$UNRELEASED" ]; then
  echo "No entries under ## Unreleased — check passed"
  exit 0
fi

# Check each entry has an issue reference (#NNN)
MISSING_REFS=""
while IFS= read -r line; do
  if ! echo "$line" | grep -qE '#[0-9]+'; then
    MISSING_REFS="${MISSING_REFS}\n  ${line}"
  fi
done <<< "$UNRELEASED"

if [ -n "$MISSING_REFS" ]; then
  echo "ERROR: RELEASE_NOTES entries must reference an issue number (#NNN)."
  echo ""
  echo "Entries missing issue references:"
  echo -e "$MISSING_REFS"
  echo ""
  echo "Example: - Fix: description of change (#123)"
  exit 1
fi

echo "RELEASE_NOTES.md check passed — all entries have issue references"
