#!/usr/bin/env bash
set -euo pipefail

# Run Python tests for Cloud Functions (cloud/scheduler/)
# Uses Docker to ensure consistent Python 3.12 environment

PYTHON_DIR="cloud/scheduler"
BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

if [ ! -d "$PYTHON_DIR" ]; then
  echo "No Python code found at ${PYTHON_DIR} — skipping"
  exit 0
fi

# Skip-CI: identical tree means code was already tested
HEAD_TREE=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
for TARGET in development staging main; do
  if [ "$BRANCH" = "$TARGET" ]; then continue; fi
  TARGET_TREE=$(git rev-parse "origin/${TARGET}^{tree}" 2>/dev/null || echo "")
  if [ "$HEAD_TREE" = "$TARGET_TREE" ]; then
    echo "==> Skipping: file content identical to ${TARGET} (already tested)"
    exit 0
  fi
done

echo "=== Cloud Function Python Tests ==="

docker run --rm \
  -v "${CI_WORKSPACE:-$(pwd)}":/app \
  -w "/app/${PYTHON_DIR}" \
  python:3.12-slim bash -c "
    pip install -q -r requirements.txt -r requirements-dev.txt
    echo '--- Lint ---'
    ruff check .
    ruff format --check .
    echo '--- Tests ---'
    python -m pytest test_main.py -v --tb=short
  "

echo "=== Cloud Function Tests Passed ==="
