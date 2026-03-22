# frozen_string_literal: true

require 'pathname'
require 'logger'
require 'json'
require 'securerandom'
require 'digest'
require 'sequel'
require 'active_support'
require 'active_support/core_ext'

module Penetrator
  class << self
    attr_reader :db

    def root
      @root ||= Pathname.new(File.expand_path('..', __dir__))
    end

    def logger
      @logger ||= Logger.new($stdout, level: log_level)
    end

    def env
      ENV.fetch('APP_ENV', 'development')
    end

    def boot!
      connect_db
      migrate!
      load_models
    end

    def boot_services!
      load_services
    end

    private

    def connect_db
      db_path = root.join('storage', "#{env}.sqlite3")
      FileUtils.mkdir_p(File.dirname(db_path))
      @db = Sequel.sqlite(db_path.to_s)
    end

    def migrate!
      Sequel.extension :migration
      migrations_dir = root.join('db', 'sequel_migrations')
      Sequel::Migrator.run(@db, migrations_dir) if migrations_dir.exist?
    end

    def load_models
      Dir[root.join('lib', 'models', '*.rb')].sort.each { |f| require f }
    end

    def load_services
      Dir[root.join('app', 'services', '**', '*.rb')].sort.each { |f| require f }
    end

    def log_level
      ENV.fetch('LOG_LEVEL', 'INFO')
    end
  end
end
