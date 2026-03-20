require 'google/cloud/bigquery'

class BigQueryLogger
  DATASET_ID = 'pentest_history'.freeze
  TABLE_PREFIX = 'scan_findings'.freeze
  EVIDENCE_MAX_LENGTH = 1000

  SCHEMA_FIELDS = [
    { name: 'fingerprint', type: 'STRING', mode: 'REQUIRED' },
    { name: 'site', type: 'STRING', mode: 'REQUIRED' },
    { name: 'scan_id', type: 'STRING', mode: 'REQUIRED' },
    { name: 'scan_date', type: 'TIMESTAMP', mode: 'REQUIRED' },
    { name: 'profile', type: 'STRING', mode: 'NULLABLE' },
    { name: 'severity', type: 'STRING', mode: 'REQUIRED' },
    { name: 'title', type: 'STRING', mode: 'REQUIRED' },
    { name: 'tool', type: 'STRING', mode: 'NULLABLE' },
    { name: 'cwe_id', type: 'STRING', mode: 'NULLABLE' },
    { name: 'url', type: 'STRING', mode: 'NULLABLE' },
    { name: 'evidence_summary', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_system', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_ref', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_pushed_at', type: 'TIMESTAMP', mode: 'NULLABLE' },
    { name: 'ticket_status', type: 'STRING', mode: 'NULLABLE' }
  ].freeze

  attr_reader :table_name

  def initialize
    @scan_mode = ENV.fetch('SCAN_MODE', 'dev')
    @table_name = "#{TABLE_PREFIX}_#{@scan_mode}"
    @client = Google::Cloud::Bigquery.new
  end

  def log_findings(scan)
    findings = scan.findings.non_duplicate
    rows = findings.map { |f| build_row(f, scan) }
    return 0 if rows.empty?

    table = ensure_table
    response = table.insert(rows) # rubocop:disable Rails/SkipsModelValidations

    if response.success?
      Rails.logger.info("[BigQueryLogger] Logged #{rows.size} findings to #{@table_name}")
    else
      Rails.logger.error("[BigQueryLogger] Insert errors: #{response.insert_errors}")
    end

    rows.size
  rescue StandardError => e
    Rails.logger.error("[BigQueryLogger] Failed: #{e.message}")
    0
  end

  def self.enabled?
    ENV['GOOGLE_CLOUD_PROJECT'].present?
  end

  private

  def build_row(finding, scan)
    {
      fingerprint: finding.fingerprint,
      site: scan.target.url_list.first,
      scan_id: scan.id,
      scan_date: scan.started_at || scan.created_at,
      profile: scan.profile,
      severity: finding.severity,
      title: finding.title,
      tool: finding.source_tool,
      cwe_id: finding.cwe_id,
      url: finding.url,
      evidence_summary: truncate_evidence(finding.evidence),
      ticket_system: ticket_field(finding, 'ticket_system'),
      ticket_ref: ticket_field(finding, 'ticket_ref'),
      ticket_pushed_at: ticket_field(finding, 'ticket_pushed_at'),
      ticket_status: ticket_field(finding, 'ticket_ref') ? 'open' : nil
    }
  end

  def ticket_field(finding, key)
    ev = finding.evidence
    ev.is_a?(Hash) ? ev[key] : nil
  end

  def truncate_evidence(evidence)
    return nil if evidence.blank?

    text = evidence.is_a?(Hash) ? evidence.to_json : evidence.to_s
    text.truncate(EVIDENCE_MAX_LENGTH)
  end

  def ensure_table
    dataset = @client.dataset(DATASET_ID) || create_dataset
    dataset.table(@table_name) || create_table(dataset)
  end

  def create_dataset
    @client.create_dataset(DATASET_ID)
  end

  def create_table(dataset)
    dataset.create_table(@table_name) do |table|
      SCHEMA_FIELDS.each do |field|
        table.schema.send(
          field[:type] == 'TIMESTAMP' ? :timestamp : :string,
          field[:name],
          mode: field[:mode]
        )
      end
    end
  end
end
