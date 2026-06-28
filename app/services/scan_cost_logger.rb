# frozen_string_literal: true

require 'google/cloud/bigquery'

class ScanCostLogger
  DATASET_ID = 'pentest_history'
  TABLE_NAME = 'scan_costs'

  # Approximate costs for estimation
  COST_PER_HOUR = { 'e2-standard-4' => 0.134, 'e2-standard-2' => 0.067 }.freeze
  SPOT_DISCOUNT = 0.6
  COST_PER_1K_ANTHROPIC_TOKENS = 0.003
  COST_PER_NVD_CALL = 0.0
  COST_PER_GCS_GB = 0.02
  COST_PER_BQ_TB_STREAMED = 6.25

  SCHEMA_FIELDS = [
    { name: 'scan_id', type: 'STRING', mode: 'REQUIRED' },
    { name: 'vm_type', type: 'STRING', mode: 'NULLABLE' },
    { name: 'vm_runtime_seconds', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'spot_instance', type: 'BOOLEAN', mode: 'NULLABLE' },
    { name: 'anthropic_tokens_used', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'nvd_api_calls', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'gcs_bytes_uploaded', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'bq_bytes_inserted', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'estimated_cost_usd', type: 'FLOAT', mode: 'NULLABLE' },
    { name: 'created_at', type: 'TIMESTAMP', mode: 'REQUIRED' }
  ].freeze

  def initialize(scan)
    @scan = scan
    @anthropic_tokens_used = 0
    @nvd_api_calls = 0
    @gcs_bytes_uploaded = 0
    @bq_bytes_inserted = 0
  end

  def track_anthropic_tokens(count)
    @anthropic_tokens_used += count
  end

  def track_nvd_api_call
    @nvd_api_calls += 1
  end

  def track_gcs_upload(bytes)
    @gcs_bytes_uploaded += bytes
  end

  def track_bq_insert(bytes)
    @bq_bytes_inserted += bytes
  end

  def cost_data
    {
      scan_id: @scan.id,
      vm_type:,
      vm_runtime_seconds: runtime_seconds,
      spot_instance: spot_instance?,
      anthropic_tokens_used: @anthropic_tokens_used,
      nvd_api_calls: @nvd_api_calls,
      gcs_bytes_uploaded: @gcs_bytes_uploaded,
      bq_bytes_inserted: @bq_bytes_inserted,
      estimated_cost_usd:
    }
  end

  def log_to_bigquery
    return false unless BigQueryLogger.enabled?

    client = Google::Cloud::Bigquery.new
    table = ensure_table(client)
    row = cost_data.merge(created_at: Time.current)
    response = table.insert([row])

    if response.success?
      Penetrator.logger.info("[ScanCostLogger] Logged cost data for scan #{@scan.id}")
      true
    else
      Penetrator.logger.error("[ScanCostLogger] Insert failed: #{response.insert_errors}")
      false
    end
  rescue StandardError => e
    Penetrator.logger.error("[ScanCostLogger] Failed: #{e.class}: #{e.message}")
    false
  end

  private

  def vm_type
    ENV.fetch('VM_MACHINE_TYPE', 'unknown')
  end

  def runtime_seconds
    @scan.duration.to_i
  end

  def spot_instance?
    ENV.fetch('SPOT_INSTANCE', 'false') == 'true'
  end

  def estimated_cost_usd
    compute_cost + anthropic_cost + storage_cost + bigquery_cost
  end

  def compute_cost
    hourly_rate = COST_PER_HOUR.fetch(vm_type, 0.134)
    hours = runtime_seconds / 3600.0
    cost = hourly_rate * hours
    spot_instance? ? cost * SPOT_DISCOUNT : cost
  end

  def anthropic_cost
    (@anthropic_tokens_used / 1000.0) * COST_PER_1K_ANTHROPIC_TOKENS
  end

  def storage_cost
    gb = @gcs_bytes_uploaded / (1024.0**3)
    gb * COST_PER_GCS_GB
  end

  def bigquery_cost
    tb = @bq_bytes_inserted / (1024.0**4)
    tb * COST_PER_BQ_TB_STREAMED
  end

  def ensure_table(client)
    dataset = client.dataset(DATASET_ID) || client.create_dataset(DATASET_ID)
    existing = dataset.table(TABLE_NAME)
    return create_table(dataset) unless existing

    migrate_schema(existing)
    existing
  end

  def migrate_schema(table)
    existing_names = table.schema.fields.map(&:name)
    missing = SCHEMA_FIELDS.reject { |f| existing_names.include?(f[:name]) }
    return if missing.empty?

    missing.each do |field|
      table.schema { |s| s.send(bq_type_method(field[:type]), field[:name], mode: 'NULLABLE') }
    end
    Penetrator.logger.info("[ScanCostLogger] Migrated schema: added #{missing.pluck(:name).join(', ')}")
  rescue StandardError => e
    Penetrator.logger.warn("[ScanCostLogger] Schema migration skipped: #{e.message}")
  end

  def create_table(dataset)
    dataset.create_table(TABLE_NAME) do |table|
      SCHEMA_FIELDS.each do |field|
        type_method = bq_type_method(field[:type])
        table.schema.send(type_method, field[:name], mode: field[:mode])
      end
    end
  end

  def bq_type_method(type)
    { 'STRING' => :string, 'INTEGER' => :integer, 'FLOAT' => :float,
      'BOOLEAN' => :boolean, 'TIMESTAMP' => :timestamp }.fetch(type)
  end
end
