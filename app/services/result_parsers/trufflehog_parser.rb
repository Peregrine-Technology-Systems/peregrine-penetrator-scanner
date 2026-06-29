module ResultParsers
  # Normalizes trufflehog `--json` NDJSON output (one JSON object per line) into
  # probe-contract findings. All detected secrets are HIGH severity — a leaked
  # credential is always serious regardless of detector type. The raw secret value
  # is never stored; uses the Redacted field only (security hygiene). See #50.
  class TrufflehogParser
    def initialize(output_file, target_url)
      @output_file = output_file
      @target_url  = target_url
    end

    def parse
      lines = File.readlines(@output_file, chomp: true).reject(&:empty?)
      lines.filter_map { |line| build_finding(line) }
    rescue Errno::ENOENT => e
      Penetrator.logger.error("[TrufflehogParser] File not found: #{e.message}")
      []
    end

    private

    def build_finding(line)
      record = JSON.parse(line)
      Contract.finding(
        source_tool: 'trufflehog', probe: 'secrets', finding_type: 'secret',
        tool_check_id: record['DetectorName'],
        severity: 'high', verified: record['Verified'],
        title: record['DetectorDescription'] || record['DetectorName'].to_s,
        location: location_for(record),
        evidence: { 'redacted' => record['Redacted'] }
      )
    rescue JSON::ParserError
      Penetrator.logger.warn('[TrufflehogParser] Skipping malformed line')
      nil
    end

    # Capture the secret's file:line:commit from trufflehog's SourceMetadata
    # (Filesystem/Git/…) so the Analyzer can locate it — the old parser dropped
    # this entirely (#971). Falls back to the scanned target when absent.
    def location_for(record)
      src = (record.dig('SourceMetadata', 'Data') || {}).values.first || {}
      Contract.file(path: src['file'] || @target_url, line: src['line'], commit: src['commit'])
    end
  end
end
