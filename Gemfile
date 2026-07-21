# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.5"

# ORM and database
gem "sequel", "~> 5.78"
gem "sqlite3", "~> 2.0"

# ActiveSupport core extensions (standalone, no Rails)
gem "activesupport", "~> 8.1"

# Cloud storage
gem "google-cloud-storage", "~> 1.44"

# BigQuery for finding history
gem "google-cloud-bigquery", "~> 1.49"

# Secret Manager — self-fetching TP model (scanner#1182, arch#672): the
# instance SA's ADC fetches the bus keyset + Synadia NATS creds directly
# instead of reading a launcher-injected file.
gem "google-cloud-secret_manager", "~> 1.5"

# HTTP client for CVE APIs and webhooks
gem "faraday", "~> 2.7"

# Bus transaction-processor adapter (scanner#1106, ADR 0004). The scanner both
# consumes scan.requested and publishes scan.completed/failed + heartbeats through
# this, never raw Pub/Sub or NATS directly. Core stays cloud-neutral (crypto +
# subjects + claim-check); the GCP sibling carries GcsSubstrate (Plane 1, prod +
# stage) + PubSubTransport (Plane 2, prod); the NATS sibling carries NatsTransport
# (Plane 2, `.stage` soak only — no live Synadia creds yet, peregrine-bus#22).
# Registry source, not a git-dep — a git credential on a private repo is fragile on
# cold CI agents; see scripts/woodpecker/lib/git-dep-auth.sh.
source "https://rubygems.pkg.github.com/Peregrine-Technology-Systems" do
  gem "peregrine_bus", "~> 0.5"
  gem "peregrine_bus_gcp", "~> 0.3"
  gem "peregrine_bus_nats", "~> 0.1"
end

# UUID support
gem "uuidtools", "~> 2.2"

# Local-dev-only tools. CI excludes the development group (BUNDLE_WITHOUT) so it
# does NOT pull `debug` — which transitively drags in irb -> rdoc -> psych, and
# psych has no precompiled linux gem so it builds from source (needs libyaml,
# absent on the CI agent). The production bake already excludes dev/test for the
# same reason; runtime YAML uses ruby's built-in psych. (#945)
group :development do
  gem "debug", platforms: %i[mri windows]
end

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "factory_bot", "~> 6.4"
  gem "faker", "~> 3.2"
  gem "simplecov", "~> 0.22", require: false
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-sequel", require: false
  gem "rubocop-rspec", "~> 3.0", require: false
  gem "rubocop-factory_bot", require: false
  gem "webmock", "~> 3.19"
end

group :test do
  gem "database_cleaner-sequel", "~> 2.0"
end
