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

# HTTP client for CVE APIs and webhooks
gem "faraday", "~> 2.7"

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
