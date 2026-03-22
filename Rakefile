# frozen_string_literal: true

require_relative 'lib/penetrator'

namespace :db do
  desc 'Run Sequel migrations'
  task :migrate do
    Penetrator.boot!
    puts 'Migrations complete'
  end
end

namespace :scan do
  desc 'Run a penetration test scan (use bin/scan for CLI)'
  task :run do
    exec(File.join(__dir__, 'bin', 'scan'))
  end

  desc 'List available scan profiles'
  task :profiles do
    Penetrator.boot!
    ScanProfile.available.each do |name|
      profile = ScanProfile.load(name)
      puts "#{name}: #{profile.description} (~#{profile.estimated_duration_minutes} min)"
      profile.phases.each do |phase|
        tools = phase.tools.map(&:tool).join(', ')
        parallel = phase.parallel ? ' [parallel]' : ''
        puts "  Phase #{phase.name}: #{tools}#{parallel}"
      end
      puts
    end
  end

  desc 'Validate scan profile YAML files'
  task :validate_profiles do
    Penetrator.boot!
    errors = []
    ScanProfile.available.each do |name|
      profile = ScanProfile.load(name)
      puts "#{name}: valid (#{profile.phases.length} phases)"
    rescue StandardError => e
      errors << "#{name}: #{e.message}"
      puts errors.last
    end
    exit 1 if errors.any?
  end
end
