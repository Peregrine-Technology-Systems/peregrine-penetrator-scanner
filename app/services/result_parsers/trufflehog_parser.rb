module ResultParsers
  # Normalizes trufflehog `--json` NDJSON output (one JSON object per line) into
  # Finding hashes. All detected secrets are HIGH severity — a leaked credential
  # is always serious regardless of the detector type. The raw secret value is
  # never stored; uses the Redacted field only (security hygiene). See #50.
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
      {
        source_tool: 'trufflehog',
        severity:    'high',
        title:       record['DetectorDescription'] || record['DetectorName'].to_s,
        url:         @target_url,
        parameter:   nil,
        cwe_id:      nil,
        cve_id:      nil,
        evidence:    {
          detector_name: record['DetectorName'],
          verified:      record['Verified'],
          redacted:      record['Redacted']
        }.compact
      }
    rescue JSON::ParserError
      Penetrator.logger.warn("[TrufflehogParser] Skipping malformed line")
      nil
    end
  end
end
