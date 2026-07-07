# frozen_string_literal: true

class ScanResultsExporter
  SCHEMA_VERSION = '2.1'

  def initialize(scan)
    @scan = scan
    @target = scan.target
    @findings = scan.findings_dataset.non_duplicate.by_severity
  end

  def export
    json = build_envelope.to_json
    @exported_sha256 = Digest::SHA256.hexdigest(json)
    gcs_path = write_and_upload(json)
    @exported_object = gcs_path
    Penetrator.logger.info("[ScanResultsExporter] Exported scan #{@scan.id} (v#{SCHEMA_VERSION}) to #{gcs_path}")
    gcs_path
  end

  # Claim-check pointer to the just-exported report blob, for the bus completion
  # event (scanner#1009): bucket + object id + the sha256 of the exact bytes
  # uploaded — never the bytes themselves. The digest is captured at export time
  # (the envelope carries a `generated_at` timestamp, so recomputing would not
  # match the stored object). Call after #export.
  def claim_check
    raise 'ScanResultsExporter#claim_check called before #export' unless @exported_object

    { bucket: ENV.fetch('GCS_BUCKET', nil), object: @exported_object, sha256: @exported_sha256 }
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
      executed: build_executed_tools(profile),
      probe_accounting: build_probe_accounting(profile)
    }
  rescue ArgumentError
    { profile: { name: @scan.profile }, planned: [], executed: build_executed_tools(nil), probe_accounting: [] }
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
        { tool: tc.tool, probe_id: Probes::Catalog.probe_id_for(tc.tool), phase: phase.name,
          parallel: phase.parallel, config: tc.config }
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
        probe_id: Probes::Catalog.probe_id_for(tool_name),
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

  # Explicit per-planned-probe run/not-run accounting (#1068) — the positive
  # signal a "planned tool absent from tool_statuses" set-difference cannot
  # give: every probe the profile planned gets an entry here, one way or the
  # other, so the Analyzer's no-silent-coverage-loss guarantee has something
  # to verify against instead of inferring absence. `executed` is keyed off
  # tool_statuses having ANY entry (running/completed/failed all count as
  # "attempted" — this is about whether the probe got a turn, not whether it
  # succeeded; `status`/`error` on the `executed` list already carry outcome).
  def build_probe_accounting(profile)
    tool_statuses = @scan.tool_statuses || {}
    planned_tools = profile.phases.flat_map { |phase| phase.tools.map(&:tool) }.uniq
    planned_tools.map do |tool|
      attempted = tool_statuses.key?(tool)
      { probe_id: Probes::Catalog.probe_id_for(tool), tool:,
        executed: attempted, skip_reason: attempted ? nil : 'not_attempted' }
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

  # Emit the stored probe output contract document (#971), stamped with the
  # per-finding provenance the DB owns. `data` is the canonical contract finding
  # (location/identifiers/scores/component/evidence/ext); the scanner is the
  # authority for id/scan_id/detected_at.
  def finding_to_hash(finding)
    (finding.data || {}).merge(
      'id' => finding.id,
      'scan_id' => finding.scan_id,
      'detected_at' => finding.created_at&.utc&.iso8601
    )
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
