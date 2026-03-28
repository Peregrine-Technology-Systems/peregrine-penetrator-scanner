class SmokeTestRunner
  CANNED_FINDINGS = [
    { source_tool: 'smoke-test', severity: 'medium', title: 'Smoke Test: Missing Security Headers',
      url: 'smoke-test://internal', cwe_id: 'CWE-693',
      evidence: { description: 'Canned finding for deploy verification' } },
    { source_tool: 'smoke-test', severity: 'low', title: 'Smoke Test: Server Version Disclosure',
      url: 'smoke-test://internal', cwe_id: 'CWE-200',
      evidence: { description: 'Canned finding for deploy verification' } },
    { source_tool: 'smoke-test', severity: 'info', title: 'Smoke Test: TLS Configuration',
      url: 'smoke-test://internal',
      evidence: { description: 'Canned finding for deploy verification' } }
  ].freeze

  def initialize(scan)
    @scan = scan
  end

  def run
    Penetrator.logger.info('[SmokeTestRunner] Starting smoke-test with canned findings')
    sleep(2) # Simulate minimal work

    create_canned_findings
    build_summary
  end

  private

  def create_canned_findings
    CANNED_FINDINGS.each do |attrs|
      Finding.create(attrs.merge(scan_id: @scan.id))
    end
  end

  def build_summary
    summary = {
      'smoke_test' => true,
      'total_findings' => CANNED_FINDINGS.length,
      'by_severity' => CANNED_FINDINGS.group_by { |f| f[:severity] }.transform_values(&:length),
      'tools_run' => ['smoke-test']
    }

    @scan.status = 'completed'
    @scan.completed_at = Time.current
    @scan.summary = summary
    @scan.save_changes

    Penetrator.logger.info("[SmokeTestRunner] Completed: #{CANNED_FINDINGS.length} canned findings")
    summary
  end
end
