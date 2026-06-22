#!/usr/bin/env bats
# Tests for reconstruct-release-notes.sh (#850).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/reconstruct-release-notes.sh"
  TMP="$(mktemp -d)"
  TARGET="${TMP}/target.md"
  LASTTAG="${TMP}/lasttag.md"
  STAGING="${TMP}/staging.md"
}

teardown() { rm -rf "$TMP"; }

@test "incident replay: misfiled entries restored to Unreleased, removed from version section" {
  # main (target), post-union-merge: Unreleased empty, #841/#842/#843 misfiled into v0.19.1
  cat > "$TARGET" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: alpha (#841)
- fix: bravo (#842)
- fix: charlie (#843)
- fix: delta (#775)
- fix: echo (#823)

## v0.19.0 — 2026-06-21

- feat: golf (#830)
EOF
  # last tag (v0.19.1): clean — only #775/#823 in v0.19.1
  cat > "$LASTTAG" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: delta (#775)
- fix: echo (#823)

## v0.19.0 — 2026-06-21

- feat: golf (#830)
EOF
  # staging: pending work still in Unreleased (incl. not-yet-cleared released ones)
  cat > "$STAGING" <<'EOF'
# Release Notes

## Unreleased

- fix: alpha (#841)
- fix: bravo (#842)
- fix: charlie (#843)
- fix: delta (#775)
- fix: echo (#823)

## v0.19.0 — 2026-06-21

- feat: golf (#830)
EOF
  run "$SCRIPT" "$TARGET" "$LASTTAG" "$STAGING"
  [ "$status" -eq 0 ]

  # #841/#842/#843 now under Unreleased
  unrel="$(awk '/^## Unreleased/{f=1;next} /^## /{f=0} f' "$TARGET")"
  echo "$unrel" | grep -q '(#841)'
  echo "$unrel" | grep -q '(#842)'
  echo "$unrel" | grep -q '(#843)'
  # …and NOT in any version section
  ver="$(awk '/^## v[0-9]/{f=1} f' "$TARGET")"
  ! echo "$ver" | grep -q '(#841)'
  ! echo "$ver" | grep -q '(#842)'
  ! echo "$ver" | grep -q '(#843)'
  # #775/#823 stay in v0.19.1 (released — not pulled into Unreleased)
  ! echo "$unrel" | grep -q '(#775)'
  echo "$ver" | grep -q '(#775)'
  echo "$ver" | grep -q '(#823)'
  # no duplicate version headers
  [ -z "$(grep -E '^## v[0-9]' "$TARGET" | sort | uniq -d)" ]
}

@test "retroactive historical entry not in staging Unreleased is untouched" {
  cat > "$TARGET" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: alpha (#841)
- fix: delta (#775)
EOF
  # last tag carries a retroactively-added entry in an OLD section (#700)
  cat > "$LASTTAG" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: delta (#775)

## v0.17.1 — 2026-04-20

- docs: backfilled historical note (#700)
EOF
  # staging Unreleased holds only the genuinely-pending #841 (NOT #700)
  cat > "$STAGING" <<'EOF'
# Release Notes

## Unreleased

- fix: alpha (#841)
EOF
  run "$SCRIPT" "$TARGET" "$LASTTAG" "$STAGING"
  [ "$status" -eq 0 ]
  # #700 stays in its historical section, never moved to Unreleased
  unrel="$(awk '/^## Unreleased/{f=1;next} /^## /{f=0} f' "$TARGET")"
  ! echo "$unrel" | grep -q '(#700)'
  grep -q '(#700)' "$TARGET"
  # #841 restored to Unreleased
  echo "$unrel" | grep -q '(#841)'
}

@test "exit 3 when staging Unreleased has nothing recoverable (never guess a release)" {
  cat > "$TARGET" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: delta (#775)
EOF
  cp "$TARGET" "$LASTTAG"
  # staging Unreleased empty
  cat > "$STAGING" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: delta (#775)
EOF
  run "$SCRIPT" "$TARGET" "$LASTTAG" "$STAGING"
  [ "$status" -eq 3 ]
}

@test "genuinely-new staging entry lands in Unreleased" {
  cat > "$TARGET" <<'EOF'
# Release Notes

## Unreleased

## v0.19.1 — 2026-06-21

- fix: delta (#775)
EOF
  cp "$TARGET" "$LASTTAG"
  cat > "$STAGING" <<'EOF'
# Release Notes

## Unreleased

- feat: brand new thing (#900)

## v0.19.1 — 2026-06-21

- fix: delta (#775)
EOF
  run "$SCRIPT" "$TARGET" "$LASTTAG" "$STAGING"
  [ "$status" -eq 0 ]
  awk '/^## Unreleased/{f=1;next} /^## /{f=0} f' "$TARGET" | grep -q '(#900)'
}

@test "exit 2 on missing input" {
  run "$SCRIPT" "/nonexistent/a" "/nonexistent/b" "/nonexistent/c"
  [ "$status" -eq 2 ]
}
