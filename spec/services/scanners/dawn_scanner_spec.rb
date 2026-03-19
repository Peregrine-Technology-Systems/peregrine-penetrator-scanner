require 'rails_helper'

RSpec.describe Scanners::DawnScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 120 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns dawn' do
      expect(scanner.tool_name).to eq('dawn')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::DawnParser).to receive(:new).and_return(instance_double(ResultParsers::DawnParser, parse: []))
    end

    it 'builds the correct dawn command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('dawn --json -F')
        expect(cmd).to include(Rails.root.to_s)
        success_result
      end

      scanner.run
    end

    it 'uses default timeout of 120 when not configured' do
      scanner_no_timeout = described_class.new(scan, {})
      allow(scanner_no_timeout).to receive(:run_command).and_return(success_result)

      expect(scanner_no_timeout).to receive(:run_command) do |_cmd, **opts|
        expect(opts[:timeout]).to eq(120)
        success_result
      end

      scanner_no_timeout.run
    end

    it 'parses results and returns findings' do
      parsed = [{ source_tool: 'dawn', title: 'CVE-2021-9999', severity: 'high' }]
      output_file = scanner.send(:output_dir).join('dawn_results.json')
      FileUtils.touch(output_file)
      allow(ResultParsers::DawnParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::DawnParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end

    it 'returns empty findings when output file does not exist' do
      result = scanner.run
      expect(result[:findings]).to eq([])
    end
  end
end
