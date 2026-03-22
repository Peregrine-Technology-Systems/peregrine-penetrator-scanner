# frozen_string_literal: true

namespace :retention do
  desc 'Purge BigQuery data older than 18 months (data retention policy)'
  task purge: :environment do
    unless BigQueryLogger.enabled?
      puts 'BigQuery not configured — skipping retention purge'
      exit 0
    end

    purger = DataRetentionPurger.new
    results = purger.purge_all

    results.each do |table, result|
      if result[:success]
        puts "  #{table}: purged #{result[:rows_deleted]} rows"
      else
        puts "  #{table}: FAILED — #{result[:error]}"
      end
    end

    puts "\nRetention purge complete at #{Time.current.iso8601}"
  end

  desc 'Dry run — show what would be purged without deleting'
  task dry_run: :environment do
    unless BigQueryLogger.enabled?
      puts 'BigQuery not configured'
      exit 0
    end

    purger = DataRetentionPurger.new
    counts = purger.preview_all

    counts.each do |table, count|
      puts "  #{table}: #{count} rows older than 18 months"
    end
  end
end
