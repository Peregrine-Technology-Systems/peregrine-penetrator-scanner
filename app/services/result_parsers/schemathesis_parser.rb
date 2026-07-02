require 'rexml/document'

module ResultParsers
  # Parses schemathesis (v4) JUnit XML output into probe-contract findings.
  # schemathesis fuzzes an OpenAPI/GraphQL operation set and reports one
  # <testcase name="METHOD /path"> per operation; a <failure> child carries the
  # check that failed (e.g. "Server error", "Response violates schema"), the HTTP
  # status, the schemathesis test-case id, and a curl reproduction line.
  #
  # We parse JUnit (not the richer NDJSON) deliberately: the testcase→finding
  # mapping is one-to-one and the XML schema is stable across v4, whereas NDJSON
  # requires reconstructing failures from an event stream. See #1018.
  class SchemathesisParser
    # Human check text (as schemathesis renders it in JUnit) → (canonical id,
    # severity, finding_type). A 5xx under fuzz input is an unhandled server-side
    # exception — robustness/DoS-relevant, so 'vulnerability'/high. Contract
    # conformance failures are correctness bugs, not directly exploitable, so
    # 'misconfiguration'/low. Unknown checks fall through to info/misconfiguration
    # and are logged (never silently dropped).
    CHECK_MAP = {
      'server error' => { id: 'server_error', severity: 'high', type: 'vulnerability' },
      'response violates schema' => { id: 'response_schema_conformance', severity: 'low', type: 'misconfiguration' },
      'undocumented http status code' => { id: 'status_code_conformance', severity: 'low', type: 'misconfiguration' },
      'malformed media type' => { id: 'content_type_conformance', severity: 'low', type: 'misconfiguration' },
      'missing content-type header' => { id: 'content_type_conformance', severity: 'low', type: 'misconfiguration' },
      'unsupported methods' => { id: 'unsupported_method_conformance', severity: 'low', type: 'misconfiguration' },
      'response time exceeded' => { id: 'response_time', severity: 'medium', type: 'misconfiguration' }
    }.freeze

    DEFAULT_CHECK = { id: 'api_fuzz_failure', severity: 'info', type: 'misconfiguration' }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      doc = REXML::Document.new(File.read(@output_file))
      doc.get_elements('//testcase').flat_map { |tc| findings_for(tc) }
    rescue REXML::ParseException, Errno::ENOENT => e
      Penetrator.logger.error("[SchemathesisParser] Parse error: #{e.message}")
      []
    end

    private

    # A testcase can carry MULTIPLE <failure> elements (one per failing scenario),
    # and a single <failure> can bundle MULTIPLE check bullets (`- Server error`
    # + `- Undocumented HTTP status code`). Emit one contract finding per
    # (failure × check) so nothing is dropped — reading only the first failure /
    # first bullet silently lost findings (#1036, caught by the scanme smoke).
    # A testcase with no <failure> (passed or <skipped>) yields nothing.
    def findings_for(testcase)
      operation = testcase.attribute('name')&.value.to_s
      method, path = operation.split(' ', 2)

      testcase.get_elements('failure').flat_map do |failure|
        body = failure.text.to_s
        check_labels(body).map { |label| build_finding(operation, method, path, body, label) }
      end
    end

    def build_finding(operation, method, path, body, label)
      check = classify(label)
      Contract.finding(
        source_tool: 'schemathesis', probe: 'api-fuzz', finding_type: check[:type],
        tool_check_id: check[:id],
        severity: check[:severity],
        title: "#{label} — #{operation}".strip,
        location: Contract.web(url: repro_url(body) || path, method: method, parameter: nil),
        evidence: {
          'status_code' => status_code(body),
          'test_case_id' => test_case_id(body),
          'reproduce' => repro_command(body),
          'response' => response_snippet(body)
        }
      )
    end

    def classify(label)
      CHECK_MAP.fetch(label.downcase) do
        Penetrator.logger.warn("[SchemathesisParser] Unmapped check '#{label}' — defaulting to info; pin it in CHECK_MAP if it matters")
        DEFAULT_CHECK
      end
    end

    # Every "- <text>" bullet in the failure body is a distinct check the scenario
    # tripped. Falls back to a single generic label when the body has no bullets.
    def check_labels(body)
      labels = body.scan(/^\s*-\s+(.+?)\s*$/).flatten
      labels.empty? ? ['API fuzz failure'] : labels
    end

    def status_code(body)
      m = body.match(/\[(\d{3})\]/)
      m ? m[1].to_i : nil
    end

    def test_case_id(body)
      m = body.match(/Test Case ID:\s*(\S+)/)
      m ? m[1] : nil
    end

    # The full URL from the curl reproduction line — the most accurate location
    # (the JUnit testcase name carries only the templated path).
    def repro_url(body)
      m = body.match(%r{(https?://\S+)\s*\z}m) || body.match(%r{(https?://\S+)})
      m ? m[1].sub(/&amp;.*/, '').strip : nil
    end

    def repro_command(body)
      idx = body.index('Reproduce with:')
      return nil unless idx

      body[idx..].sub('Reproduce with:', '').strip.split("\n").map(&:strip).reject(&:empty?).first
    end

    def response_snippet(body)
      m = body.match(/`(.+?)`/m)
      m ? m[1][0, 500] : nil
    end
  end
end
