# frozen_string_literal: true

class ScanResultsExporter
  include ReportGenerators::Helpers

  SCHEMA_VERSION = '1.0'

  def initialize(scan)
    @scan = scan
    @target = scan.target
    @findings = scan.findings.non_duplicate.by_severity
  end

  def export
    json = build_envelope.to_json
    gcs_path = write_and_upload(json)
    Penetrator.logger.info("[ScanResultsExporter] Exported scan #{@scan.id} (v#{SCHEMA_VERSION}) to #{gcs_path}")
    gcs_path
  end

  def build_envelope
    {
      schema_version: SCHEMA_VERSION,
      metadata: build_metadata,
      summary: build_summary,
      findings: @findings.map { |f| finding_to_hash(f) }
    }
  end

  private

  def build_metadata
    {
      scan_id: @scan.id,
      target_name: @target.name,
      target_urls: @target.url_list,
      profile: @scan.profile,
      started_at: @scan.started_at&.iso8601,
      completed_at: @scan.completed_at&.iso8601,
      duration_seconds: @scan.duration&.to_i,
      tool_statuses: @scan.tool_statuses || {},
      generated_at: Time.current.iso8601
    }
  end

  def build_summary
    summary = @scan.summary || {}
    {
      total_findings: summary['total_findings'] || @findings.size,
      by_severity: summary['by_severity'] || @findings.group(:severity).count,
      tools_run: summary['tools_run'] || (@scan.tool_statuses || {}).keys,
      duration_seconds: summary['duration_seconds'] || @scan.duration&.to_i,
      executive_summary: summary['executive_summary']
    }
  end

  def write_and_upload(json)
    local_dir = Penetrator.root.join('tmp', 'scan_results', @scan.id)
    FileUtils.mkdir_p(local_dir)
    local_path = local_dir.join('scan_results.json')
    File.write(local_path, json)

    remote_path = "scan-results/#{@target.id}/#{@scan.id}/scan_results.json"
    StorageService.new.upload(local_path.to_s, remote_path, content_type: 'application/json')
    remote_path
  ensure
    FileUtils.rm_rf(local_dir) if local_dir && File.directory?(local_dir)
  end
end
