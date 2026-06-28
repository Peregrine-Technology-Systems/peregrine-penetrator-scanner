class ScanSummaryBuilder
  def initialize(scan)
    @scan = scan
  end

  def build
    non_dup = @scan.findings_dataset.non_duplicate
    {
      total_findings: non_dup.count,
      by_severity: non_dup.group_and_count(:severity).all.to_h { |r| [r[:severity], r[:count]] },
      tools_run: @scan.tool_statuses.keys,
      duration_seconds: @scan.duration&.to_i
    }
  end
end
