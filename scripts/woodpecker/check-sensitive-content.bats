#!/usr/bin/env bats
# Tests for the pre-publish sensitive-content lint.

SCRIPT_SRC="$BATS_TEST_DIRNAME/check-sensitive-content.sh"

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q
  git config user.email "t@example.com"
  git config user.name "t"
  # place the script at its real path so its self-exclude regex applies
  mkdir -p scripts/woodpecker
  cp "$SCRIPT_SRC" scripts/woodpecker/check-sensitive-content.sh
  chmod +x scripts/woodpecker/check-sensitive-content.sh
  echo "baseline" > a.txt
  git add a.txt scripts/woodpecker/check-sensitive-content.sh
  git commit -qm init
}
teardown() { rm -rf "$TMP"; }

run_check() { run scripts/woodpecker/check-sensitive-content.sh "$@"; }

stage() { printf '%s\n' "$1" > probe.txt; git add probe.txt; }

@test "clean staged content passes" {
  stage "the scanner orchestrates ZAP and nuclei against a target"
  run_check
  [ "$status" -eq 0 ]
}

@test "infra hostname is blocked" {
  stage "deploy to host d3ci42.peregrinetechsys.net"
  run_check
  [ "$status" -eq 1 ]
}

@test "service-account email is blocked" {
  stage "runs as penetrator-scanner@some-project.iam.gserviceaccount.com"
  run_check
  [ "$status" -eq 1 ]
}

@test "internal cross-repo issue ref is blocked" {
  stage "tracked in infra#4071 for the launcher"
  run_check
  [ "$status" -eq 1 ]
}

@test "private 10.x IP is blocked" {
  stage "metrics bind to 10.116.0.5:9100"
  run_check
  [ "$status" -eq 1 ]
}

@test "internal report bucket is blocked" {
  stage "results land in peregrine-pentest-dev-pentest-reports"
  run_check
  [ "$status" -eq 1 ]
}

@test "allow-sensitive marker permits a flagged line" {
  stage "example only foo.peregrinetechsys.net  # allow-sensitive: documented example"
  run_check
  [ "$status" -eq 0 ]
}

@test "diff-scoping: pre-existing exposure does not block a clean new commit" {
  printf 'host d3ci42.peregrinetechsys.net\n' > legacy.txt
  git add legacy.txt && git commit -qm "pre-existing exposure"
  stage "a perfectly clean new line"
  run_check
  [ "$status" -eq 0 ]
}

@test "--all flags pre-existing exposure" {
  printf 'host d3ci42.peregrinetechsys.net\n' > legacy.txt
  git add legacy.txt && git commit -qm "pre-existing"
  run_check --all
  [ "$status" -eq 1 ]
}

@test "gitignored extra-patterns file adds specific blocks" {
  printf 'my-internal-project-x\n' > .sensitive-extra-patterns
  stage "references my-internal-project-x directly"
  run_check
  [ "$status" -eq 1 ]
}

@test "--range checks added lines in a commit range" {
  git rev-parse HEAD > /dev/null
  base="$(git rev-parse HEAD)"
  printf 'host vm.peregrinetechsys.com\n' > ranged.txt
  git add ranged.txt && git commit -qm "adds exposure"
  run_check --range "${base}..HEAD"
  [ "$status" -eq 1 ]
}
