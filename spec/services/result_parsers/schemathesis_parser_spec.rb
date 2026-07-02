require 'sequel_helper'

RSpec.describe ResultParsers::SchemathesisParser do
  def parse_xml(xml)
    tmpfile = Tempfile.new(['schemathesis', '.xml'])
    tmpfile.write(xml)
    tmpfile.close
    described_class.new(tmpfile.path).parse
  ensure
    tmpfile.unlink
  end

  # The real captured schemathesis v4 JUnit output (Petstore run, #1018).
  let(:real_fixture) { Penetrator.root.join('spec/fixtures/schemathesis_results.xml') }

  describe '#parse against the real captured fixture' do
    subject(:findings) { described_class.new(real_fixture).parse }

    it 'emits one api-fuzz finding per failed operation, skipping passed/skipped ones' do
      # The fixture has 12 testcases: 7 skipped, 5 failures.
      expect(findings.length).to eq(5)
      expect(findings).to all(include('source_tool' => 'schemathesis', 'probe' => 'api-fuzz'))
    end

    it 'classifies a 5xx as a high vulnerability' do
      server_error = findings.find { |f| f['tool_check_id'] == 'server_error' }
      expect(server_error).to include('finding_type' => 'vulnerability', 'severity' => 'high')
      expect(server_error['evidence']['status_code']).to eq(500)
      expect(server_error['title']).to match(%r{Server error — POST /store/order|POST /user})
    end

    it 'classifies a schema-conformance failure as a low misconfiguration' do
      schema = findings.find { |f| f['tool_check_id'] == 'response_schema_conformance' }
      expect(schema).to include('finding_type' => 'misconfiguration', 'severity' => 'low')
    end

    it 'captures the method + full reproduce URL as the web location' do
      f = findings.first
      expect(f['location']).to include('kind' => 'web')
      expect(f['location']['method']).to match(/GET|POST|PUT|DELETE|PATCH/)
      expect(f['location']['url']).to start_with('http')
    end

    it 'captures the schemathesis test-case id in evidence' do
      expect(findings.map { |f| f['evidence']['test_case_id'] }).to all(be_a(String))
    end
  end

  describe '#parse against the real multi-failure scanme fixture (#1036)' do
    # Real schemathesis output where one testcase has 2 <failure> elements and
    # another bundles 2 check bullets in one <failure> — the case the earlier
    # single-failure-per-testcase parser silently under-reported.
    subject(:findings) { described_class.new(Penetrator.root.join('spec/fixtures/schemathesis_multifailure.xml')).parse }

    it 'emits one finding per (failure x check), dropping nothing' do
      expect(findings.length).to eq(4)
      expect(findings.map { |f| f['tool_check_id'] }).to contain_exactly(
        'server_error', 'status_code_conformance', 'unsupported_method_conformance', 'response_schema_conformance'
      )
    end

    it 'captures BOTH bullets of a single multi-check failure (echo: server_error + undocumented status)' do
      echo = findings.select { |f| f['title'].include?('/api/echo') }
      expect(echo.map { |f| f['tool_check_id'] }).to contain_exactly('server_error', 'status_code_conformance')
    end

    it 'captures the schema-violation in the SECOND failure element (previously dropped)' do
      schema = findings.find { |f| f['tool_check_id'] == 'response_schema_conformance' }
      expect(schema).to include('finding_type' => 'misconfiguration', 'severity' => 'low')
      expect(schema['title']).to include('/api/user/{id}')
    end
  end

  describe '#parse edge cases' do
    it 'returns [] for a suite with only skipped/passed testcases' do
      xml = <<~XML
        <?xml version="1.0"?>
        <testsuites><testsuite name="schemathesis">
          <testcase name="GET /a" time="0.1"><skipped type="skipped">No examples</skipped></testcase>
          <testcase name="GET /b" time="0.1"/>
        </testsuite></testsuites>
      XML
      expect(parse_xml(xml)).to eq([])
    end

    it 'maps an unknown check to info/misconfiguration without raising' do
      xml = <<~XML
                <?xml version="1.0"?>
                <testsuites><testsuite name="schemathesis">
                  <testcase name="POST /x" time="0.1"><failure type="failure">1. Test Case ID: ZZ1

        - Some brand new check

        [418] I'm a teapot:

            `nope`</failure></testcase>
                </testsuite></testsuites>
      XML
      results = parse_xml(xml)
      expect(results.length).to eq(1)
      expect(results.first).to include('tool_check_id' => 'api_fuzz_failure', 'severity' => 'info',
                                       'finding_type' => 'misconfiguration')
      expect(results.first['evidence']['status_code']).to eq(418)
    end

    it 'returns [] for malformed XML rather than raising' do
      expect(parse_xml('<testsuites><not-closed')).to eq([])
    end

    it 'returns [] for a missing file rather than raising' do
      expect(described_class.new('/nonexistent/schemathesis.xml').parse).to eq([])
    end
  end
end
