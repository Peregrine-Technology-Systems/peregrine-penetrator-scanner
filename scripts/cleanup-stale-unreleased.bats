#!/usr/bin/env bats

# Tests for scripts/cleanup-stale-unreleased.sh — Rule #13 / #1394 cleanup.
#
# Run locally:
#   bats scripts/cleanup-stale-unreleased.bats
# CI runs this via .woodpecker/ci.yaml's script-tests step.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/cleanup-stale-unreleased.sh"
  TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "no-op when file missing" {
  run "$SCRIPT" /no/such/file
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "no-op when no Unreleased section" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## v0.1.0
- initial
EOF
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]
  grep -q "## v0.1.0" RELEASE_NOTES.md
  grep -q "initial" RELEASE_NOTES.md
}

@test "no-op when Unreleased empty" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## Unreleased

## v0.1.0
- feat: X (#1)
EOF
  ORIGINAL=$(cat RELEASE_NOTES.md)
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]
  [ "$(cat RELEASE_NOTES.md)" = "$ORIGINAL" ]
}

@test "no-op when Unreleased entries are all genuinely new" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## Unreleased

- fix: NEW (#2)
- fix: ANOTHER NEW (#3)

## v0.1.0
- feat: X (#1)
EOF
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]
  grep -q "fix: NEW (#2)" RELEASE_NOTES.md
  grep -q "fix: ANOTHER NEW (#3)" RELEASE_NOTES.md
}

@test "strips a single stale Unreleased line — the #1394 case" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## Unreleased

- feat: X (#1)
- fix: NEW (#2)

## v0.1.0 — 2026-01-01
- feat: X (#1)
EOF
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]

  # stale "feat: X (#1)" under Unreleased dropped
  UNRELEASED_BLOCK=$(awk '/^## Unreleased/,/^## v/' RELEASE_NOTES.md | grep -v '^## ')
  [[ "$UNRELEASED_BLOCK" != *"feat: X (#1)"* ]]

  # genuinely-new "fix: NEW (#2)" preserved
  [[ "$UNRELEASED_BLOCK" == *"fix: NEW (#2)"* ]]

  # versioned section untouched
  grep -q "^## v0.1.0 — 2026-01-01$" RELEASE_NOTES.md
  grep -q "feat: X (#1)" RELEASE_NOTES.md
}

@test "strips multiple stale lines across multiple versioned sections" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## Unreleased

- feat: A (#1)
- fix: B (#2)
- fix: C (#3)
- feat: NEW (#99)

## v0.2.0 — 2026-02-01
- fix: C (#3)

## v0.1.0 — 2026-01-01
- feat: A (#1)
- fix: B (#2)
EOF
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]

  UNRELEASED_BLOCK=$(awk '/^## Unreleased/,/^## v/' RELEASE_NOTES.md | grep -v '^## ')
  [[ "$UNRELEASED_BLOCK" != *"feat: A (#1)"* ]]
  [[ "$UNRELEASED_BLOCK" != *"fix: B (#2)"* ]]
  [[ "$UNRELEASED_BLOCK" != *"fix: C (#3)"* ]]
  [[ "$UNRELEASED_BLOCK" == *"feat: NEW (#99)"* ]]
}

@test "trailing whitespace does not defeat the match" {
  printf '# Release Notes\n\n## Unreleased\n\n- feat: X (#1)   \n- fix: NEW (#2)\n\n## v0.1.0\n- feat: X (#1)\n' > RELEASE_NOTES.md
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]
  UNRELEASED_BLOCK=$(awk '/^## Unreleased/,/^## v/' RELEASE_NOTES.md | grep -v '^## ')
  [[ "$UNRELEASED_BLOCK" != *"feat: X (#1)"* ]]
  [[ "$UNRELEASED_BLOCK" == *"fix: NEW (#2)"* ]]
}

@test "preserves blank lines and ordering within Unreleased" {
  cat > RELEASE_NOTES.md <<'EOF'
# Release Notes

## Unreleased

- fix: ONE (#1)

- fix: TWO (#2)

## v0.1.0
EOF
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 0 ]
  # Both entries survive in order
  ONE_LINE=$(grep -n "fix: ONE" RELEASE_NOTES.md | head -1 | cut -d: -f1)
  TWO_LINE=$(grep -n "fix: TWO" RELEASE_NOTES.md | head -1 | cut -d: -f1)
  [ "$ONE_LINE" -lt "$TWO_LINE" ]
}

@test "errors instead of writing empty file on internal failure" {
  # Replace awk to force empty output, simulating a bug.
  PATH="$TMPDIR:$PATH"
  cat > "$TMPDIR/awk" <<'EOF'
#!/usr/bin/env bash
exit 0  # produce no output
EOF
  chmod +x "$TMPDIR/awk"
  echo "real content" > RELEASE_NOTES.md
  run "$SCRIPT" RELEASE_NOTES.md
  [ "$status" -eq 2 ]
  # Original file preserved
  [ "$(cat RELEASE_NOTES.md)" = "real content" ]
}
