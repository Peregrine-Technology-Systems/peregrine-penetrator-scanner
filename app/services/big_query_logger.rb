# frozen_string_literal: true

require 'google/cloud/bigquery'

class BigQueryLogger
  DATASET_ID = 'pentest_history'.freeze
  FINDINGS_TABLE_PREFIX = 'scan_findings'.freeze
  METADATA_TABLE_PREFIX = 'scan_metadata'.freeze

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

  def initialize
    @scan_mode = ENV.fetch('SCAN_MODE', 'dev')
    @findings_table_name = "#{FINDINGS_TABLE_PREFIX}_#{@scan_mode}"
    @metadata_table_name = "#{METADATA_TABLE_PREFIX}_#{@scan_mode}"
    @client = Google::Cloud::Bigquery.new
  end

  # New JSON-first interface: load from the versioned scan results envelope
  def log_from_json(scan_results)
    findings_count = log_findings_from_json(scan_results)
    log_metadata_from_json(scan_results)
    findings_count
  rescue StandardError => e
    Penetrator.logger.error("[BigQueryLogger] Failed: #{e.message}")
    0
  end

  # Legacy interface: load from ActiveRecord scan object (backward compatible)
  def log_findings(scan)
    findings = scan.findings.non_duplicate
    rows = findings.map { |f| build_row_from_ar(f, scan) }
    return 0 if rows.empty?

    insert_rows(ensure_findings_table, rows, 'findings')
  rescue StandardError => e
    Penetrator.logger.error("[BigQueryLogger] Failed: #{e.message}")
    0
  end

  def self.enabled?
    ENV['GOOGLE_CLOUD_PROJECT'].present?
  end

  # Keep legacy alias for backward compatibility
  def table_name
    findings_table_name
  end

  private

  def log_findings_from_json(scan_results)
    schema_version = scan_results['schema_version'] || scan_results[:schema_version]
    metadata = scan_results['metadata'] || scan_results[:metadata] || {}
    findings = scan_results['findings'] || scan_results[:findings] || []
    return 0 if findings.empty?

    rows = findings.map { |f| build_row_from_json(f, metadata, schema_version) }
    insert_rows(ensure_findings_table, rows, 'findings')
  end

  def log_metadata_from_json(scan_results)
    schema_version = scan_results['schema_version'] || scan_results[:schema_version]
    metadata = scan_results['metadata'] || scan_results[:metadata] || {}
    summary = scan_results['summary'] || scan_results[:summary] || {}

    row = {
      scan_id: metadata['scan_id'] || metadata[:scan_id],
      target_name: metadata['target_name'] || metadata[:target_name],
      profile: metadata['profile'] || metadata[:profile],
      duration_seconds: summary['duration_seconds'] || summary[:duration_seconds],
      tool_statuses: (metadata['tool_statuses'] || metadata[:tool_statuses] || {}).to_json,
      schema_version: schema_version,
      scan_date: metadata['started_at'] || metadata[:started_at] || Time.now.iso8601,
      total_findings: summary['total_findings'] || summary[:total_findings],
      by_severity: (summary['by_severity'] || summary[:by_severity] || {}).to_json
    }

    insert_rows(ensure_metadata_table, [row], 'metadata')
  end

  def build_row_from_json(finding, metadata, schema_version)
    evidence = finding['evidence'] || finding[:evidence]
    {
      fingerprint: finding['fingerprint'] || finding[:id] || SecureRandom.hex(32),
      site: Array(metadata['target_urls'] || metadata[:target_urls]).first,
      scan_id: metadata['scan_id'] || metadata[:scan_id],
      scan_date: metadata['started_at'] || metadata[:started_at] || Time.now.iso8601,
      profile: metadata['profile'] || metadata[:profile],
      schema_version: schema_version,
      severity: finding['severity'] || finding[:severity],
      title: finding['title'] || finding[:title],
      tool: finding['source_tool'] || finding[:source_tool],
      cwe_id: finding['cwe_id'] || finding[:cwe_id],
      cve_id: finding['cve_id'] || finding[:cve_id],
      url: finding['url'] || finding[:url],
      parameter: finding['parameter'] || finding[:parameter],
      cvss_score: finding['cvss_score'] || finding[:cvss_score],
      epss_score: finding['epss_score'] || finding[:epss_score],
      kev_known_exploited: finding['kev_known_exploited'] || finding[:kev_known_exploited],
      evidence: evidence.is_a?(Hash) ? evidence.to_json : evidence&.to_s,
      ticket_system: ticket_from_evidence(evidence, 'ticket_system'),
      ticket_ref: ticket_from_evidence(evidence, 'ticket_ref'),
      ticket_pushed_at: ticket_from_evidence(evidence, 'ticket_pushed_at'),
      ticket_status: ticket_from_evidence(evidence, 'ticket_ref') ? 'open' : nil
    }
  end

  # Legacy: build row from ActiveRecord objects
  def build_row_from_ar(finding, scan)
    {
      fingerprint: finding.fingerprint,
      site: scan.target.url_list.first,
      scan_id: scan.id,
      scan_date: scan.started_at || scan.created_at,
      profile: scan.profile,
      schema_version: ScanResultsExporter::SCHEMA_VERSION,
      severity: finding.severity,
      title: finding.title,
      tool: finding.source_tool,
      cwe_id: finding.cwe_id,
      cve_id: finding.cve_id,
      url: finding.url,
      parameter: finding.parameter,
      cvss_score: finding.cvss_score,
      epss_score: finding.epss_score,
      kev_known_exploited: finding.kev_known_exploited,
      evidence: finding.evidence.is_a?(Hash) ? finding.evidence.to_json : finding.evidence&.to_s,
      ticket_system: ticket_field(finding, 'ticket_system'),
      ticket_ref: ticket_field(finding, 'ticket_ref'),
      ticket_pushed_at: ticket_field(finding, 'ticket_pushed_at'),
      ticket_status: ticket_field(finding, 'ticket_ref') ? 'open' : nil
    }
  end

  def ticket_from_evidence(evidence, key)
    evidence.is_a?(Hash) ? (evidence[key] || evidence[key.to_sym]) : nil
  end

  def ticket_field(finding, key)
    ev = finding.evidence
    ev.is_a?(Hash) ? ev[key] : nil
  end

  def insert_rows(table, rows, label)
    response = table.insert(rows) # rubocop:disable Rails/SkipsModelValidations

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
