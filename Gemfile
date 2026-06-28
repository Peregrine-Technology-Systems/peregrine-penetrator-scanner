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

# Pin psych to the version ruby 4.0.5 ships as a precompiled default gem.
# psych is only a transitive dep (rdoc, >= 4.0.0); without this pin bundler
# resolves it to the newest rubygems version (5.4.0), which has no precompiled
# linux binary and is built from source — needing libyaml (yaml.h) at install
# time, which fails on a CI agent without libyaml-dev. The built-in 5.3.1 is
# already compiled into ruby, so no source build is needed. Bump alongside the
# `ruby "4.0.5"` pin above. (#945; the agent-image libyaml class-fix is tracked
# in the infrastructure repo)
gem "psych", "5.3.1"

group :development, :test do
  gem "debug", platforms: %i[mri windows]
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
