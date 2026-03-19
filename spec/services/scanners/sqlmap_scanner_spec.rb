require 'rails_helper'

RSpec.describe Scanners::SqlmapScanner do
  let(:target) { create(:target, urls: ['https://example.com/page?id=1'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { level: 2, risk: 2, timeout: 600 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns sqlmap' do
      expect(scanner.tool_name).to eq('sqlmap')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::SqlmapParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'builds the correct sqlmap command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('sqlmap -u')
        expect(cmd).to include('--batch')
        expect(cmd).to include('--level=2')
        expect(cmd).to include('--risk=2')
        expect(cmd).to include('--forms')
        expect(cmd).to include('--crawl=2')
        success_result
      end

      scanner.run
    end

    context 'with default level and risk' do
      let(:tool_config) { { timeout: 600 } }

      it 'uses level 1 and risk 1 as defaults' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('--level=1')
          expect(cmd).to include('--risk=1')
          success_result
        end

        scanner.run
      end
    end

    context 'with no injectable URLs' do
      let(:target) { create(:target, urls: ['https://example.com/page'].to_json) }

      it 'skips scan and returns empty findings' do
        expect(scanner).not_to receive(:run_command)

        result = scanner.run
        expect(result[:success]).to be true
        expect(result[:findings]).to eq([])
        expect(result[:skipped]).to be true
      end
    end

    context 'with multiple injectable URLs' do
      let(:target) { create(:target, urls: ['https://example.com/a?id=1', 'https://example.com/b?name=x'].to_json) }

      it 'runs sqlmap for each URL' do
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end

    it 'parses results for each URL' do
      parsed = [{ source_tool: 'sqlmap', title: 'SQL Injection - boolean-based blind', severity: 'high' }]
      allow(ResultParsers::SqlmapParser).to receive_message_chain(:new, :parse).and_return(parsed)

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end
  end
end
