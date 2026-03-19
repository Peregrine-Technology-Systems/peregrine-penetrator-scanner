require 'rails_helper'

RSpec.describe Scanners::ZapScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { mode: 'baseline', timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }
  let(:warning_result) { { stdout: '', stderr: '', exit_code: 2, success: false } }
  let(:failure_result) { { stdout: '', stderr: 'error occurred', exit_code: 1, success: false } }

  describe '#tool_name' do
    it 'returns zap' do
      expect(scanner.tool_name).to eq('zap')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::ZapParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'builds the correct baseline command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('zap-baseline.py')
        expect(cmd).to include('-t https://example.com')
        expect(cmd).to include('-J')
        expect(cmd).to include('-I')
        success_result
      end

      scanner.run
    end

    context 'with full mode' do
      let(:tool_config) { { mode: 'full', timeout: 300 } }

      it 'builds the full scan command' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('zap-full-scan.py')
          success_result
        end

        scanner.run
      end
    end

    context 'with api mode' do
      let(:tool_config) { { mode: 'api', timeout: 300 } }

      it 'builds the api scan command' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('zap-api-scan.py')
          success_result
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
      allow(scanner).to receive(:run_command).and_return(warning_result)

      result = scanner.run
      expect(result[:success]).to be true
    end

    it 'treats exit code 1 as failure' do
      allow(scanner).to receive(:run_command).and_return(failure_result)

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
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end
  end
end
