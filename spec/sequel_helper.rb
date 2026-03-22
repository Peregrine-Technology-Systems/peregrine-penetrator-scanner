# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/config/'
  add_filter '/db/'
  add_filter '/vendor/'
  minimum_coverage 90
end

ENV['APP_ENV'] = 'test'

require_relative '../lib/penetrator'

Penetrator.boot!

require 'database_cleaner-sequel'
require 'factory_bot'
require 'faker'
require 'webmock/rspec'

Dir[Penetrator.root.join('spec', 'factories', '**', '*.rb')].each { |f| require f }

# Configure FactoryBot for Sequel (uses save instead of save!)
FactoryBot.define do
  to_create { |instance| instance.save }
end

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  config.before(:suite) do
    DatabaseCleaner[:sequel].strategy = :transaction
    DatabaseCleaner[:sequel].clean_with(:truncation)
  end

  config.around do |example|
    DatabaseCleaner[:sequel].cleaning { example.run }
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed
end

WebMock.disable_net_connect!(allow_localhost: true)
