# frozen_string_literal: true

require 'pathname'
require 'logger'
require 'json'
require 'securerandom'
require 'digest'
require 'sequel'
require 'active_support'
require 'active_support/core_ext'
require 'faraday'

module Penetrator
  class << self
    attr_reader :db

    def root
      @root ||= Pathname.new(File.expand_path('..', __dir__))
    end

    def logger
      @logger ||= build_logger
    end

    def env
      ENV.fetch('APP_ENV', 'development')
    end

    def boot!
      logger.info("[Penetrator] Booting in #{env} environment")
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
      return unless migrations_dir.exist?
      return if Sequel::Migrator.is_current?(@db, migrations_dir)

      Sequel::Migrator.run(@db, migrations_dir)
    end

    def load_models
      Dir[root.join('lib', 'models', '*.rb')].each { |f| require f }
      # Value objects in app/models/ (not Sequel models)
      Dir[root.join('app', 'models', '*.rb')].each { |f| require f }
    end

    def load_services
      services_dir = root.join('app', 'services')

      # 1. Load base classes that subdirectories inherit from
      loaded = []
      %w[scanner_base].each do |base|
        path = services_dir.join("#{base}.rb")
        if path.exist?
          require path.to_s
          loaded << File.expand_path(path)
        end
      end

      # 3. Load all subdirectory files (scanners, parsers, ai, cve_clients, etc.)
      Dir[services_dir.join('**', '*.rb')].each do |f|
        next if loaded.include?(File.expand_path(f))
        next if File.dirname(f) == services_dir.to_s

        require f
        loaded << File.expand_path(f)
      end

      # 4. Load remaining top-level service files
      Dir[services_dir.join('*.rb')].each do |f|
        require f unless loaded.include?(File.expand_path(f))
      end
    end

    def build_logger
      logger = Logger.new($stdout, level: ENV.fetch('LOG_LEVEL', 'INFO'))
      logger.formatter = proc { |severity, time, _progname, msg|
        "#{time.strftime('%H:%M:%S')} [#{severity}] #{msg}\n"
      }
      logger
    end
  end
end
