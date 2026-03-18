require 'rails_helper'

RSpec.describe Scanners::ZapScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { mode: 'baseline', timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_status) { instance_double(Process::Status, exitstatus: 0, success?: true) }
  let(:warning_status) { instance_double(Process::Status, exitstatus: 2, success?: false) }
  let(:failure_status) { instance_double(Process::Status, exitstatus: 1, success?: false) }

  describe '#tool_name' do
    it 'returns zap' do
      expect(scanner.tool_name).to eq('zap')
    end
  end

  describe '#run' do
    before do
      allow(Open3).to receive(:capture3).and_return(['', '', success_status])
      allow(ResultParsers::ZapParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'builds the correct baseline command' do
      expect(Open3).to receive(:capture3) do |cmd, **_opts|
        expect(cmd).to include('zap-baseline.py')
        expect(cmd).to include('-t https://example.com')
        expect(cmd).to include('-J')
        expect(cmd).to include('-I')
        ['', '', success_status]
      end

      scanner.run
    end

    context 'with full mode' do
      let(:tool_config) { { mode: 'full', timeout: 300 } }

      it 'builds the full scan command' do
        expect(Open3).to receive(:capture3) do |cmd, **_opts|
          expect(cmd).to include('zap-full-scan.py')
          ['', '', success_status]
        end

        scanner.run
      end
    end

    context 'with api mode' do
      let(:tool_config) { { mode: 'api', timeout: 300 } }

      it 'builds the api scan command' do
        expect(Open3).to receive(:capture3) do |cmd, **_opts|
          expect(cmd).to include('zap-api-scan.py')
          ['', '', success_status]
        end

        scanner.run
      end
    end

    context 'with unknown mode' do
      let(:tool_config) { { mode: 'invalid', timeout: 300 } }

      it 'raises ArgumentError' do
        result = scanner.run
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown ZAP mode')
      end
    end

    it 'treats exit code 2 as success (warnings found)' do
      allow(Open3).to receive(:capture3).and_return(['', '', warning_status])

      result = scanner.run
      expect(result[:success]).to be true
    end

    it 'treats exit code 1 as failure' do
      allow(Open3).to receive(:capture3).and_return(['', 'error occurred', failure_status])

      result = scanner.run
      expect(result[:success]).to be false
    end

    it 'parses results on success' do
      parsed_findings = [{ source_tool: 'zap', title: 'XSS', severity: 'high' }]
      output_file = scanner.send(:output_dir).join('zap_results.json')
      FileUtils.touch(output_file)
      allow(ResultParsers::ZapParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::ZapParser, parse: parsed_findings)
      )

      result = scanner.run
      expect(result[:findings]).to eq(parsed_findings)
    end

    it 'returns empty findings when output file does not exist' do
      result = scanner.run
      expect(result[:findings]).to eq([])
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://test.com'].to_json) }

      it 'runs command for each URL' do
        expect(Open3).to receive(:capture3).twice.and_return(['', '', success_status])
        scanner.run
      end
    end
  end
end
