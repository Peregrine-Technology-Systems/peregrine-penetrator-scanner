# frozen_string_literal: true

require 'google/cloud/bigquery'

class DataRetentionPurger
  RETENTION_MONTHS = 18
  DATASET_ID = 'pentest_history'
  AUDIT_DATASET_ID = 'audit_logs'

  PURGEABLE_TABLES = {
    'scan_findings' => { date_column: 'scan_date', dataset: DATASET_ID },
    'scan_metadata' => { date_column: 'scan_date', dataset: DATASET_ID },
    'scan_costs' => { date_column: 'logged_at', dataset: DATASET_ID }
  }.freeze

  AUDIT_TABLES = {
    'penetrator_events' => { date_column: 'timestamp', dataset: AUDIT_DATASET_ID }
  }.freeze

  def initialize
    @client = Google::Cloud::Bigquery.new
    @scan_mode = ENV.fetch('SCAN_MODE', 'dev')
    @cutoff = Time.now.utc - (RETENTION_MONTHS * 30.44 * 24 * 3600)
  end

  def purge_all
    results = {}

    all_tables.each do |base_name, config|
      table_name = resolve_table_name(base_name)
      results[table_name] = purge_table(config[:dataset], table_name, config[:date_column])
    end

    log_purge_event(results)
    results
  end

  def preview_all
    counts = {}

    all_tables.each do |base_name, config|
      table_name = resolve_table_name(base_name)
      counts[table_name] = count_purgeable(config[:dataset], table_name, config[:date_column])
    end

    counts
  end

  private

  def all_tables
    PURGEABLE_TABLES.merge(AUDIT_TABLES)
  end

  def resolve_table_name(base_name)
    return base_name if AUDIT_TABLES.key?(base_name)

    "#{base_name}_#{@scan_mode}"
  end

  def purge_table(dataset_id, table_name, date_column)
    dataset = @client.dataset(dataset_id)
    return { success: true, rows_deleted: 0 } unless dataset&.table(table_name)

    cutoff_str = @cutoff.strftime('%Y-%m-%d %H:%M:%S UTC')
    sql = "DELETE FROM `#{dataset_id}.#{table_name}` WHERE #{date_column} < '#{cutoff_str}'"
    result = @client.query(sql)
    rows_deleted = result.total || 0

    Penetrator.logger.info("[DataRetentionPurger] Purged #{rows_deleted} rows from #{table_name}")
    { success: true, rows_deleted: }
  rescue StandardError => e
    Penetrator.logger.error("[DataRetentionPurger] Failed to purge #{table_name}: #{e.message}")
    { success: false, rows_deleted: 0, error: e.message }
  end

  def count_purgeable(dataset_id, table_name, date_column)
    dataset = @client.dataset(dataset_id)
    return 0 unless dataset&.table(table_name)

    cutoff_str = @cutoff.strftime('%Y-%m-%d %H:%M:%S UTC')
    sql = "SELECT COUNT(*) AS cnt FROM `#{dataset_id}.#{table_name}` WHERE #{date_column} < '#{cutoff_str}'"
    result = @client.query(sql)
    result.first[:cnt]
  rescue StandardError => e
    Penetrator.logger.error("[DataRetentionPurger] Preview failed for #{table_name}: #{e.message}")
    -1
  end

  def log_purge_event(results)
    Penetrator.logger.info(
      {
        event: 'data_retention_purge',
        timestamp: Time.now.utc.iso8601,
        retention_months: RETENTION_MONTHS,
        cutoff_date: @cutoff.iso8601,
        results: results.transform_values { |r| { rows_deleted: r[:rows_deleted], success: r[:success] } }
      }.to_json
    )
  end
end
