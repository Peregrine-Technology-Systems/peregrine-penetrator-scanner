#!/usr/bin/env bash
set -euo pipefail

# Run RSpec tests inside Docker (agent-independent — no Ruby required on host)
# Enforces: 100% test pass + 90% minimum line coverage
MINIMUM_COVERAGE=90

docker run --rm \
  -v "$CI_WORKSPACE":/app -w /app \
  ruby:3.2.2 bash -c "
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq libsqlite3-dev > /dev/null 2>&1
    bundle install --jobs 4 --retry 3 --path vendor/bundle
    APP_ENV=test bundle exec rspec --format documentation

    # Enforce minimum coverage
    if [ -f coverage/.last_run.json ]; then
      COVERAGE=\$(ruby -rjson -e 'puts JSON.parse(File.read(\"coverage/.last_run.json\"))[\"result\"][\"line\"]')
      echo \"Line coverage: \${COVERAGE}%\"
      PASS=\$(ruby -e \"puts \${COVERAGE} >= ${MINIMUM_COVERAGE} ? 'yes' : 'no'\")
      if [ \"\$PASS\" != 'yes' ]; then
        echo \"ERROR: Coverage \${COVERAGE}% is below ${MINIMUM_COVERAGE}% minimum\"
        exit 1
      fi
      echo \"Coverage gate passed (>= ${MINIMUM_COVERAGE}%)\"
    else
      echo 'WARNING: No coverage data found — skipping coverage check'
    fi
  "
