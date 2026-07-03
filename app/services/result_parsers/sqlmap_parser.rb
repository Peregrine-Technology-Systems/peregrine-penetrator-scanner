require 'json'

module ResultParsers
  # Parses sqlmap's machine-readable `--report-json` output instead of regexing the
  # human log (#822). The old log-regex was silent-OK: any change to sqlmap's log
  # wording yielded zero findings while the scan "passed". The JSON report is the
  # same structure sqlmap's REST API emits — a stable envelope with a typed `data[]`
  # array — so a format change surfaces as a schema mismatch we can detect, not a
  # silent empty.
  #
  # Envelope: { "success", "data": [ {"type", "type_name", "value"} ... ], "error", "meta" }
  # We key on the numeric `type` (stable across versions):
  #   0 TARGET · 1 TECHNIQUES (injection points) · 2 DBMS_FINGERPRINT
  # A TECHNIQUES value is a list of injections, each already sanitized by sqlmap to:
  #   { "place", "parameter", "dbms", "dbms_version", "data": [ {"technique", "title", "payload"} ] }
  class SqlmapParser
    CONTENT_TECHNIQUES = 1
    CONTENT_DBMS_FINGERPRINT = 2

    # Raised when the report exists but its structure can't be understood — a loud
    # signal of upstream format drift, never swallowed into an empty result.
    class MalformedReport < StandardError; end

    def initialize(report_path, url)
      @report_path = report_path
      @url = url
    end

    def parse
      return [] unless @report_path && File.exist?(@report_path)

      report = JSON.parse(File.read(@report_path))
      data = report['data']
      # Envelope drift (data missing / not an array) is a real failure, not "no
      # findings" — surface it loudly rather than returning a silent empty.
      raise MalformedReport, "unexpected report envelope: #{report.keys.inspect}" unless data.is_a?(Array)

      injections = techniques(data)
      dbms_fallback = dbms_fingerprint(data)

      findings = injections.flat_map { |injection| findings_for(injection, dbms_fallback) }

      # Positive broken-state counterpart: sqlmap reported injection point(s) but we
      # extracted nothing — that means the technique shape drifted. Fail loud.
      if findings.empty? && injections.any?
        raise MalformedReport,
              "#{injections.length} injection point(s) present but no findings parsed — technique shape drift?"
      end

      findings
    rescue JSON::ParserError => e
      raise MalformedReport, "malformed sqlmap report JSON: #{e.message}"
    end

    private

    def techniques(data)
      entry = data.find { |d| d['type'] == CONTENT_TECHNIQUES }
      value = entry && entry['value']
      value.is_a?(Array) ? value : []
    end

    def dbms_fingerprint(data)
      entry = data.find { |d| d['type'] == CONTENT_DBMS_FINGERPRINT }
      # e.g. "back-end DBMS: MySQL >= 5.0.12" → "MySQL >= 5.0.12"
      entry && entry['value'].to_s.sub(/\Aback-end DBMS:\s*/, '').strip
    end

    # One finding per (parameter × technique) — SQLi severity is high regardless of
    # technique (per CWE-89), but the technique, title, payload, place and DBMS are
    # carried so the finding is no longer flattened to a single generic row.
    def findings_for(injection, dbms_fallback)
      parameter = injection['parameter']
      place = injection['place']
      dbms = normalize_dbms(injection['dbms']) || dbms_fallback

      Array(injection['data']).map do |technique|
        build(parameter:, place:, dbms:, technique:)
      end
    end

    def build(parameter:, place:, dbms:, technique:)
      type_name = technique['technique'].to_s
      Contract.finding(
        source_tool: 'sqlmap', probe: 'injection', finding_type: 'vulnerability',
        tool_check_id: type_name, severity: 'high',
        title: "SQL Injection (#{type_name})",
        location: Contract.web(url: @url, parameter:),
        identifiers: [Contract.identifier('cwe', 'CWE-89')],
        evidence: {
          'injection_type' => type_name,
          'place' => place,
          'parameter' => parameter,
          'dbms' => dbms,
          'title' => technique['title'],
          'payload' => technique['payload']
        }.compact
      )
    end

    # injection.dbms is a string ("MySQL") or a list (["MySQL", "MariaDB"]).
    def normalize_dbms(dbms)
      return nil if dbms.nil?

      Array(dbms).join(', ')
    end
  end
end
