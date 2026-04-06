# frozen_string_literal: true

require 'google/cloud/bigquery'

class BigQueryLogger
  DATASET_ID = 'pentest_history'
  FINDINGS_TABLE_PREFIX = 'scan_findings'
  METADATA_TABLE_PREFIX = 'scan_metadata'

  FINDINGS_SCHEMA = [
    { name: 'fingerprint', type: 'STRING', mode: 'REQUIRED' },
    { name: 'site', type: 'STRING', mode: 'REQUIRED' },
    { name: 'scan_id', type: 'STRING', mode: 'REQUIRED' },
    { name: 'scan_date', type: 'TIMESTAMP', mode: 'REQUIRED' },
    { name: 'profile', type: 'STRING', mode: 'NULLABLE' },
    { name: 'schema_version', type: 'STRING', mode: 'REQUIRED' },
    { name: 'severity', type: 'STRING', mode: 'REQUIRED' },
    { name: 'title', type: 'STRING', mode: 'REQUIRED' },
    { name: 'tool', type: 'STRING', mode: 'NULLABLE' },
    { name: 'cwe_id', type: 'STRING', mode: 'NULLABLE' },
    { name: 'cve_id', type: 'STRING', mode: 'NULLABLE' },
    { name: 'url', type: 'STRING', mode: 'NULLABLE' },
    { name: 'parameter', type: 'STRING', mode: 'NULLABLE' },
    { name: 'cvss_score', type: 'FLOAT', mode: 'NULLABLE' },
    { name: 'cvss_vector', type: 'STRING', mode: 'NULLABLE' },
    { name: 'epss_score', type: 'FLOAT', mode: 'NULLABLE' },
    { name: 'kev_known_exploited', type: 'BOOLEAN', mode: 'NULLABLE' },
    { name: 'evidence', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_system', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_ref', type: 'STRING', mode: 'NULLABLE' },
    { name: 'ticket_pushed_at', type: 'TIMESTAMP', mode: 'NULLABLE' },
    { name: 'ticket_status', type: 'STRING', mode: 'NULLABLE' }
  ].freeze

  METADATA_SCHEMA = [
    { name: 'scan_id', type: 'STRING', mode: 'REQUIRED' },
    { name: 'target_name', type: 'STRING', mode: 'REQUIRED' },
    { name: 'profile', type: 'STRING', mode: 'NULLABLE' },
    { name: 'duration_seconds', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'tool_statuses', type: 'STRING', mode: 'NULLABLE' },
    { name: 'schema_version', type: 'STRING', mode: 'REQUIRED' },
    { name: 'scan_date', type: 'TIMESTAMP', mode: 'REQUIRED' },
    { name: 'total_findings', type: 'INTEGER', mode: 'NULLABLE' },
    { name: 'by_severity', type: 'STRING', mode: 'NULLABLE' }
  ].freeze

  attr_reader :findings_table_name, :metadata_table_name

  def initialize(cost_logger: nil)
    @scan_mode = ENV.fetch('SCAN_MODE', 'dev')
    @findings_table_name = "#{FINDINGS_TABLE_PREFIX}_#{@scan_mode}"
    @metadata_table_name = "#{METADATA_TABLE_PREFIX}_#{@scan_mode}"
    @client = Google::Cloud::Bigquery.new
    @cost_logger = cost_logger
  end

  def log_from_json(scan_results)
    schema_version = flex(scan_results, 'schema_version')
    metadata = flex(scan_results, 'metadata') || {}
    summary = flex(scan_results, 'summary') || {}
    findings = flex(scan_results, 'findings') || []

    findings_count = log_findings(findings, metadata, schema_version)
    log_metadata(metadata, summary, schema_version)
    findings_count
  rescue StandardError => e
    Penetrator.logger.error("[BigQueryLogger] Failed: #{e.message}")
    0
  end

  # Legacy interface: load from Sequel scan object
  def log_findings_from_scan(scan)
    findings = scan.findings_dataset.non_duplicate
    schema_version = ScanResultsExporter::SCHEMA_VERSION
    metadata = { scan_id: scan.id, target_urls: scan.target.url_list,
                 started_at: scan.started_at || scan.created_at, profile: scan.profile }

    rows = findings.map { |f| build_finding_row(normalize_ar_finding(f), metadata, schema_version) }
    return 0 if rows.empty?

    insert_rows(ensure_findings_table, rows, 'findings')
  rescue StandardError => e
    Penetrator.logger.error("[BigQueryLogger] Failed: #{e.message}")
    0
  end

  def self.enabled?
    ENV['GOOGLE_CLOUD_PROJECT'].present?
  end

  def table_name
    findings_table_name
  end

  private

  # Flexible key access — handles both string and symbol keys
  def flex(hash, key)
    hash[key] || hash[key.to_sym]
  end

  def log_findings(findings, metadata, schema_version)
    return 0 if findings.empty?

    rows = findings.map { |f| build_finding_row(f, metadata, schema_version) }
    insert_rows(ensure_findings_table, rows, 'findings')
  end

  def log_metadata(metadata, summary, schema_version)
    row = {
      scan_id: flex(metadata, 'scan_id'),
      target_name: flex(metadata, 'target_name'),
      profile: flex(metadata, 'profile'),
      duration_seconds: flex(summary, 'duration_seconds'),
      tool_statuses: (flex(metadata, 'tool_statuses') || {}).to_json,
      schema_version:,
      scan_date: flex(metadata, 'started_at') || Time.now.iso8601,
      total_findings: flex(summary, 'total_findings'),
      by_severity: (flex(summary, 'by_severity') || {}).to_json
    }

    insert_rows(ensure_metadata_table, [row], 'metadata')
  end

  def build_finding_row(finding, metadata, schema_version)
    evidence = flex(finding, 'evidence')
    {
      fingerprint: flex(finding, 'fingerprint') || flex(finding, 'id') || SecureRandom.hex(32),
      site: Array(flex(metadata, 'target_urls')).first,
      scan_id: flex(metadata, 'scan_id'),
      scan_date: flex(metadata, 'started_at') || Time.now.iso8601,
      profile: flex(metadata, 'profile'),
      schema_version:,
      severity: flex(finding, 'severity'),
      title: flex(finding, 'title'),
      tool: flex(finding, 'source_tool'),
      cwe_id: flex(finding, 'cwe_id'),
      cve_id: flex(finding, 'cve_id'),
      url: flex(finding, 'url'),
      parameter: flex(finding, 'parameter'),
      cvss_score: flex(finding, 'cvss_score'),
      cvss_vector: flex(finding, 'cvss_vector'),
      epss_score: flex(finding, 'epss_score'),
      kev_known_exploited: flex(finding, 'kev_known_exploited'),
      evidence: evidence.is_a?(Hash) ? evidence.to_json : evidence&.to_s,
      ticket_system: ticket_from(evidence, 'ticket_system'),
      ticket_ref: ticket_from(evidence, 'ticket_ref'),
      ticket_pushed_at: ticket_from(evidence, 'ticket_pushed_at'),
      ticket_status: ticket_from(evidence, 'ticket_ref') ? 'open' : nil
    }
  end

  def normalize_ar_finding(finding)
    {
      fingerprint: finding.fingerprint, id: finding.id,
      severity: finding.severity, title: finding.title,
      source_tool: finding.source_tool, cwe_id: finding.cwe_id,
      cve_id: finding.cve_id, url: finding.url, parameter: finding.parameter,
      cvss_score: finding.cvss_score, cvss_vector: finding.cvss_vector,
      epss_score: finding.epss_score, kev_known_exploited: finding.kev_known_exploited,
      evidence: finding.evidence
    }
  end

  def ticket_from(evidence, key)
    return nil unless evidence.is_a?(Hash)

    evidence[key] || evidence[key.to_sym]
  end

  def insert_rows(table, rows, label)
    @cost_logger&.track_bq_insert(rows.to_json.bytesize)
    response = table.insert(rows)

    if response.success?
      Penetrator.logger.info("[BigQueryLogger] Logged #{rows.size} #{label} rows to #{table.table_id}")
    else
      Penetrator.logger.error("[BigQueryLogger] Insert errors (#{label}): #{response.insert_errors}")
    end

    rows.size
  end

  def ensure_findings_table
    dataset = ensure_dataset
    dataset.table(@findings_table_name) || create_table(dataset, @findings_table_name, FINDINGS_SCHEMA)
  end

  def ensure_metadata_table
    dataset = ensure_dataset
    dataset.table(@metadata_table_name) || create_table(dataset, @metadata_table_name, METADATA_SCHEMA)
  end

  def ensure_dataset
    @client.dataset(DATASET_ID) || @client.create_dataset(DATASET_ID)
  end

  def create_table(dataset, table_name, schema_fields)
    dataset.create_table(table_name) do |table|
      schema_fields.each do |field|
        type_method = case field[:type]
                      when 'TIMESTAMP' then :timestamp
                      when 'FLOAT' then :float
                      when 'INTEGER' then :integer
                      when 'BOOLEAN' then :boolean
                      else :string
                      end
        table.schema.send(type_method, field[:name], mode: field[:mode])
      end
    end
  end
end
