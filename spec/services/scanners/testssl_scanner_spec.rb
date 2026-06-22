require 'sequel_helper'

RSpec.describe Scanners::TestsslScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 600 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns testssl' do
      expect(scanner.tool_name).to eq('testssl')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::TestsslParser).to receive(:new)
        .and_return(instance_double(ResultParsers::TestsslParser, parse: []))
    end

    it 'builds a testssl command writing JSON, quiet, no --fast' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('testssl.sh')
        expect(cmd).to include('--jsonfile')
        expect(cmd).to include('--quiet')
        expect(cmd).not_to include('--fast') # --fast distorts results (engine/cmdline noise)
        expect(cmd).to include('https://example.com')
        success_result
      end

      scanner.run
    end

    it 'parses results and returns findings' do
      parsed = [{ source_tool: 'testssl', title: 'No KEMs offered', severity: 'low' }]
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("testssl_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::TestsslParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::TestsslParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://a.com', 'https://b.com'].to_json) }

      it 'runs testssl once per URL' do
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end
  end
end
