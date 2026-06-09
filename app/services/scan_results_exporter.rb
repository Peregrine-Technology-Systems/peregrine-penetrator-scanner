# frozen_string_literal: true

class ScanResultsExporter
  SCHEMA_VERSION = '1.3'

  def initialize(scan, cost_logger: nil)
    @scan = scan
    @target = scan.target
    @findings = scan.findings_dataset.non_duplicate.by_severity
    @cost_logger = cost_logger
  end

  def export
    json = build_envelope.to_json
    @cost_logger&.track_gcs_upload(json.bytesize)
    gcs_path = write_and_upload(json)
    Penetrator.logger.info("[ScanResultsExporter] Exported scan #{@scan.id} (v#{SCHEMA_VERSION}) to #{gcs_path}")
    gcs_path
  end

  def build_envelope
    {
      schema_version: SCHEMA_VERSION,
      tool_chain: build_tool_chain,
      metadata: build_metadata,
      summary: build_summary,
      findings: @findings.map { |f| finding_to_hash(f) }
    }
  end

  def build_tool_chain
    profile = ScanProfile.load(@scan.profile)
    {
      profile: { name: profile.name, description: profile.description,
                 estimated_duration_minutes: profile.estimated_duration_minutes },
      planned: build_planned_tools(profile),
      executed: build_executed_tools(profile)
    }
  rescue ArgumentError
    { profile: { name: @scan.profile }, planned: [], executed: build_executed_tools(nil) }
  end

  private

  def build_metadata
    {
      scan_id: @scan.id,
      scanner_version: Penetrator::VERSION,
      scanner_commit: ENV.fetch('GIT_COMMIT', 'unknown'),
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

  def build_planned_tools(profile)
    profile.phases.flat_map do |phase|
      phase.tools.map do |tc|
        { tool: tc.tool, phase: phase.name, parallel: phase.parallel, config: tc.config }
      end
    end
  end

  def build_executed_tools(profile)
    tool_statuses = @scan.tool_statuses || {}
    tool_statuses.map do |tool_name, status|
      started = status['started_at'] || status[:started_at]
      completed = status['updated_at'] || status[:updated_at]
      duration = started && completed ? time_diff(started, completed) : nil
      {
        tool: tool_name,
        phase: find_phase(profile, tool_name),
        status: status['status'] || status[:status],
        started_at: started,
        completed_at: completed,
        duration_seconds: duration,
        exit_code: status['exit_code'] || status[:exit_code],
        findings_count: status['findings_count'] || status[:findings_count],
        error: status['error'] || status[:error]
      }
    end
  end

  def find_phase(profile, tool_name)
    return nil unless profile

    profile.phases.find { |p| p.tools.any? { |t| t.tool == tool_name } }&.name
  end

  def time_diff(started, completed)
    (Time.parse(completed) - Time.parse(started)).to_i
  rescue ArgumentError, TypeError
    nil
  end

  def build_summary
    summary = @scan.summary || {}
    {
      total_findings: summary['total_findings'] || @findings.count,
      by_severity: summary['by_severity'] || @findings.group_and_count(:severity).all.to_h { |r| [r[:severity], r[:count]] },
      tools_run: summary['tools_run'] || (@scan.tool_statuses || {}).keys,
      duration_seconds: summary['duration_seconds'] || @scan.duration&.to_i,
      executive_summary: summary['executive_summary'],
      cms_inventory: summary['cms_inventory']
    }
  end

  def finding_to_hash(finding)
    {
      id: finding.id,
      source_tool: finding.source_tool,
      severity: finding.severity,
      title: finding.title,
      url: finding.url,
      parameter: finding.parameter,
      cwe_id: finding.cwe_id,
      cve_id: finding.cve_id,
      cvss_score: finding.cvss_score,
      cvss_vector: finding.cvss_vector,
      epss_score: finding.epss_score,
      kev_known_exploited: finding.kev_known_exploited,
      evidence: finding.evidence,
      ai_assessment: finding.ai_assessment
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
