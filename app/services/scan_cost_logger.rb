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

  SCHEMA_FIELDS = [
    { name: 'scan_id', type: 'STRING', mode: 'REQUIRED' },
    { name: 'vm_type', type: 'STRING', mode: 'NULLABLE' },
    { name: 'vm_runtime_seconds', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'spot_instance', type: 'BOOLEAN', mode: 'NULLABLE' },
    { name: 'anthropic_tokens_used', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'nvd_api_calls', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'gcs_bytes_uploaded', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'estimated_cost_usd', type: 'FLOAT', mode: 'NULLABLE' },
    { name: 'created_at', type: 'TIMESTAMP', mode: 'REQUIRED' }
  ].freeze

  def initialize(scan)
    @scan = scan
    @anthropic_tokens_used = 0
    @nvd_api_calls = 0
    @gcs_bytes_uploaded = 0
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

  def cost_data
    {
      scan_id: @scan.id,
      vm_type:,
      vm_runtime_seconds: runtime_seconds,
      spot_instance: spot_instance?,
      anthropic_tokens_used: @anthropic_tokens_used,
      nvd_api_calls: @nvd_api_calls,
      gcs_bytes_uploaded: @gcs_bytes_uploaded,
      estimated_cost_usd:
    }
  end

  def log_to_bigquery
    return false unless BigQueryLogger.enabled?

    client = Google::Cloud::Bigquery.new
    table = ensure_table(client)
    row = cost_data.merge(created_at: Time.current)
    table.insert([row]) # rubocop:disable Rails/SkipsModelValidations

    Rails.logger.info("[ScanCostLogger] Logged cost data for scan #{@scan.id}")
    true
  rescue StandardError => e
    Rails.logger.error("[ScanCostLogger] Failed: #{e.message}")
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
    compute_cost + anthropic_cost + storage_cost
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

  def ensure_table(client)
    dataset = client.dataset(DATASET_ID) || client.create_dataset(DATASET_ID)
    dataset.table(TABLE_NAME) || create_table(dataset)
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
