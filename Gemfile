source "https://rubygems.org"

ruby "3.2.2"

gem "rails", "~> 7.1.3"
gem "sqlite3", "~> 1.4"
gem "puma", ">= 5.0"
gem "tzinfo-data", platforms: %i[windows jruby]
gem "bootsnap", require: false

# PDF generation
gem "grover"

# Cloud storage
gem "google-cloud-storage", "~> 1.44"

# BigQuery for finding history
gem "google-cloud-bigquery", "~> 1.49"

# HTTP client for CVE APIs and webhooks
gem "faraday", "~> 2.7"

# Anthropic Claude API
gem "ruby-anthropic", "~> 0.4"

# Email
gem "mail", "~> 2.8"

# UUID support
gem "uuidtools", "~> 2.2"

group :development, :test do
  gem "debug", platforms: %i[mri windows]
  gem "rspec-rails", "~> 6.1"
  gem "factory_bot_rails", "~> 6.4"
  gem "faker", "~> 3.2"
  gem "simplecov", "~> 0.22", require: false
  gem "rubocop", "~> 1.62.0", require: false
  gem "rubocop-rails", "~> 2.24.0", require: false
  gem "rubocop-rspec", "~> 2.27.0", require: false
  gem "webmock", "~> 3.19"
end

group :test do
  gem "shoulda-matchers", "~> 6.1"
  gem "database_cleaner-active_record", "~> 2.1"
end
