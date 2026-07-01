require 'sequel_helper'

RSpec.describe Scanners::SchemathesisScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 1200 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 1, success: false } }

  describe '#tool_name' do
    it 'returns schemathesis' do
      expect(scanner.tool_name).to eq('schemathesis')
    end
  end

  describe '#run with an explicit schema_url (discovery bypassed)' do
    let(:tool_config) { { timeout: 1200, schema_url: 'https://example.com/openapi.json', rate_limit: '3/s' } }

    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::SchemathesisParser).to receive(:new)
        .and_return(instance_double(ResultParsers::SchemathesisParser, parse: []))
    end

    it 'never probes for a schema when one is supplied' do
      expect(scanner).not_to receive(:discover_schema)
      scanner.run
    end

    it 'builds an unauthenticated schemathesis run command with junit output + rate limit' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to start_with('schemathesis run')
        expect(cmd).to include('https://example.com/openapi.json')
        expect(cmd).to include('--report junit --report-junit-path')
        expect(cmd).to include('--rate-limit 3/s')
        expect(cmd).not_to include('--auth')
        expect(cmd).not_to include('--header')
        success_result
      end
      scanner.run
    end

    it 'parses the junit report into findings' do
      parsed = [{ 'source_tool' => 'schemathesis', 'probe' => 'api-fuzz', 'severity' => 'high' }]
      output_file = scanner.send(:output_dir).join("schemathesis_#{Digest::MD5.hexdigest('https://example.com/openapi.json')}.xml")
      FileUtils.touch(output_file)
      allow(ResultParsers::SchemathesisParser).to receive(:new).with(output_file)
                                                               .and_return(instance_double(ResultParsers::SchemathesisParser, parse: parsed))

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end
  end

  describe '#run with schema auto-discovery' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::SchemathesisParser).to receive(:new)
        .and_return(instance_double(ResultParsers::SchemathesisParser, parse: []))
    end

    it 'fuzzes the first well-known path that returns an OpenAPI document' do
      allow(scanner).to receive(:fetch) do |uri|
        uri.to_s.end_with?('/openapi.json') ? '{"openapi":"3.0.0","paths":{}}' : nil
      end
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('https://example.com/openapi.json')
        success_result
      end
      scanner.run
    end

    it 'is NOT-APPLICABLE (success, zero findings, no run) when no schema is reachable' do
      allow(scanner).to receive(:fetch).and_return(nil)
      expect(scanner).not_to receive(:run_command)

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq([])
    end
  end

  describe 'schema-discovery helpers' do
    it 'derives the origin from a URL, dropping path and default port' do
      expect(scanner.send(:origin_of, 'https://example.com/api/v1/pets')).to eq('https://example.com')
    end

    it 'keeps a non-default port in the origin' do
      expect(scanner.send(:origin_of, 'http://example.com:8080/x')).to eq('http://example.com:8080')
    end

    it 'returns nil origin for a non-HTTP URL' do
      expect(scanner.send(:origin_of, 'ftp://example.com')).to be_nil
    end

    it 'recognizes an OpenAPI document by its top-level version key' do
      expect(scanner.send(:looks_like_openapi?, '{"openapi": "3.1.0"}')).to be true
      expect(scanner.send(:looks_like_openapi?, 'swagger: "2.0"')).to be true
    end

    it 'rejects a body that is not an OpenAPI document' do
      expect(scanner.send(:looks_like_openapi?, '<html><body>login</body></html>')).to be false
    end
  end
end
