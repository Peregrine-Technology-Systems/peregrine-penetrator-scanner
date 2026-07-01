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
      'response time exceeded' => { id: 'response_time', severity: 'medium', type: 'misconfiguration' }
    }.freeze

    DEFAULT_CHECK = { id: 'api_fuzz_failure', severity: 'info', type: 'misconfiguration' }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      doc = REXML::Document.new(File.read(@output_file))
      doc.get_elements('//testcase').filter_map { |tc| build(tc) }
    rescue REXML::ParseException, Errno::ENOENT => e
      Penetrator.logger.error("[SchemathesisParser] Parse error: #{e.message}")
      []
    end

    private

    # A testcase with no <failure> (passed or <skipped>) yields no finding.
    def build(testcase)
      failure = testcase.elements['failure']
      return nil unless failure

      operation = testcase.attribute('name')&.value.to_s
      method, path = operation.split(' ', 2)
      body = failure.text.to_s

      check = classify(body)
      Contract.finding(
        source_tool: 'schemathesis', probe: 'api-fuzz', finding_type: check[:type],
        tool_check_id: check[:id],
        severity: check[:severity],
        title: "#{check_label(body)} — #{operation}".strip,
        location: Contract.web(url: repro_url(body) || path, method: method, parameter: nil),
        evidence: {
          'status_code' => status_code(body),
          'test_case_id' => test_case_id(body),
          'reproduce' => repro_command(body),
          'response' => response_snippet(body)
        }
      )
    end

    def classify(body)
      label = check_label(body).downcase
      CHECK_MAP.fetch(label) do
        Penetrator.logger.warn("[SchemathesisParser] Unmapped check '#{label}' — defaulting to info; pin it in CHECK_MAP if it matters")
        DEFAULT_CHECK
      end
    end

    # The check name is the first "- <text>" bullet after the Test Case ID line.
    def check_label(body)
      m = body.match(/^\s*-\s+(.+?)\s*$/)
      m ? m[1] : 'API fuzz failure'
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
