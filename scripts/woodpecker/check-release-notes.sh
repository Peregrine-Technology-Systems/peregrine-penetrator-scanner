#!/usr/bin/env bash
set -euo pipefail

# Enforce RELEASE_NOTES.md update when code files change
# Mirrors the pre-commit hook logic but runs in CI

# Get files changed in this commit
CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD)

# Check if any code files changed (exclude docs, config, specs-only)
CODE_FILES=$(echo "$CHANGED_FILES" | grep -E '\.(rb|py|sh|yaml|yml|rake|erb)$' \
  | grep -v '^spec/' \
  | grep -v '^\.woodpecker/' \
  | grep -v '^docs/' \
  | grep -v 'CLAUDE\.md' \
  | grep -v 'README\.md' || true)

if [ -z "$CODE_FILES" ]; then
  echo "No code files changed — RELEASE_NOTES check skipped"
  exit 0
fi

# Check if RELEASE_NOTES.md was updated
if echo "$CHANGED_FILES" | grep -q 'RELEASE_NOTES.md'; then
  echo "RELEASE_NOTES.md updated — check passed"
  exit 0
fi

echo "ERROR: Code files changed but RELEASE_NOTES.md was not updated."
echo ""
echo "Changed code files:"
echo "$CODE_FILES" | sed 's/^/  /'
echo ""
echo "Add a line under '## Unreleased' in RELEASE_NOTES.md describing your change."
exit 1
