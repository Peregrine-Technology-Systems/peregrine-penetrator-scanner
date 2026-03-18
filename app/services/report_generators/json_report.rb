module ReportGenerators
  class JsonReport
    include Helpers

    def initialize(scan:, findings:)
      @scan = scan
      @findings = findings
    end

    def generate
      {
        metadata: {
          scan_id: @scan.id,
          target: @scan.target.name,
          profile: @scan.profile,
          started_at: @scan.started_at&.iso8601,
          completed_at: @scan.completed_at&.iso8601,
          duration_seconds: @scan.duration&.to_i,
          generated_at: Time.current.iso8601
        },
        summary: @scan.summary,
        findings: @findings.map { |f| finding_to_hash(f) }
      }.to_json
    end

    def filename
      "scan_#{@scan.id}_report.json"
    end

    def content_type
      'application/json'
    end
  end
end
