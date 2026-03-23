require 'open3'

class ScanOrchestrator
  SCANNER_MAP = {
    'zap' => Scanners::ZapScanner,
    'nuclei' => Scanners::NucleiScanner,
    'sqlmap' => Scanners::SqlmapScanner,
    'ffuf' => Scanners::FfufScanner,
    'nikto' => Scanners::NiktoScanner,
    'dawn' => Scanners::DawnScanner
  }.freeze

  attr_reader :scan, :profile

  def initialize(scan)
    @scan = scan
    @profile = ScanProfile.load(scan.profile)
    @discovered_urls = []
  end

  def execute
    mark_running
    Penetrator.logger.info("[ScanOrchestrator] Starting #{profile.name} scan for #{scan.target.name}")

    if profile.smoke
      run_smoke_checks
    else
      run_scan_phases
    end

    scan
  rescue StandardError => e
    scan.update(status: 'failed', completed_at: Time.current, error_message: e.message)
    Penetrator.logger.error("[ScanOrchestrator] Scan failed: #{e.message}")
    raise
  end

  private

  def run_scan_phases
    profile.phases.each do |phase|
      Penetrator.logger.info("[ScanOrchestrator] Phase: #{phase.name}")
      run_phase(phase)
    end

    FindingNormalizer.new(scan).normalize
    mark_completed
    Penetrator.logger.info("[ScanOrchestrator] Scan completed: #{scan.findings_dataset.count} findings")
  end

  def run_smoke_checks
    checker = SmokeChecker.new(scan)
    summary = checker.run

    scan.status = checker.passed? ? 'completed' : 'failed'
    scan.completed_at = Time.current
    scan.summary = summary
    scan.save_changes

    status = checker.passed? ? 'PASSED' : 'FAILED'
    Penetrator.logger.info("[ScanOrchestrator] Smoke test #{status}")
    checker.results.each do |check, result|
      Penetrator.logger.info("[SmokeChecker] #{check}: #{result[:status]} — #{result[:detail]}")
    end
  end

  def mark_running
    scan.update(status: 'running', started_at: Time.current)
  end

  def mark_completed
    scan.status = 'completed'
    scan.completed_at = Time.current
    scan.summary = ScanSummaryBuilder.new(scan).build
    scan.save_changes
  end

  def run_phase(phase)
    if phase.parallel && phase.tools.length > 1
      phase.tools.map { |tc| Thread.new { run_tool(tc) } }.each(&:join)
    else
      phase.tools.each { |tool_config| run_tool(tool_config) }
    end
  end

  def run_tool(tool_config)
    scanner_class = SCANNER_MAP[tool_config.tool]
    return log_unknown_tool(tool_config.tool) unless scanner_class

    feed_discovered_urls(tool_config)
    result = scanner_class.new(scan, tool_config.config.dup).run

    @discovered_urls.concat(result[:discovered_urls]) if result[:discovered_urls]
    save_findings(result[:findings]) if result[:findings]&.any?
  rescue StandardError => e
    Penetrator.logger.error("[ScanOrchestrator] Tool #{tool_config.tool} failed: #{e.message}")
  end

  def feed_discovered_urls(tool_config)
    return unless @discovered_urls.any? && tool_config.tool != 'ffuf'

    all_urls = (scan.target.url_list + @discovered_urls).uniq
    scan.target.urls = all_urls
    scan.target.save_changes
  end

  def log_unknown_tool(tool)
    Penetrator.logger.warn("[ScanOrchestrator] Unknown tool: #{tool}")
  end

  def save_findings(findings)
    findings.each do |finding_attrs|
      Finding.create(finding_attrs.merge(scan_id: scan.id))
    rescue Sequel::ValidationFailed => e
      Penetrator.logger.warn("[ScanOrchestrator] Duplicate finding skipped: #{e.message}")
    end
  end
end
