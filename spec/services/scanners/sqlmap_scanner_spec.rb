require 'sequel_helper'

RSpec.describe Scanners::SqlmapScanner do
  let(:target) { create(:target, urls: ['https://example.com/page?id=1'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
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
      allow(ResultParsers::SqlmapParser).to receive(:new).and_return(instance_double(ResultParsers::SqlmapParser, parse: []))
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

    it 'requests machine-readable output via --report-json (#822)' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to match(/--report-json=\S+sqlmap_report_[a-f0-9]+\.json/)
        success_result
      end

      scanner.run
    end

    it 'warns loudly when no report is produced (unsupported flag / crash, #822)' do
      # run_command is stubbed, so no report file is written — the guard should fire.
      expect(Penetrator.logger).to receive(:warn).with(/no --report-json output.*may not support/)
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

      it 'caps the per-URL timeout by the aggregate remaining budget (#824)' do
        expect(scanner).to receive(:run_command).twice do |_cmd, **opts|
          # per_url_timeout is 600; remaining (of the 1800 default) is larger, so
          # each call gets the per-URL cap, never an unbounded value.
          expect(opts[:timeout]).to be <= 600
          expect(opts[:timeout]).to be > 0
          success_result
        end
        scanner.run
      end

      it 'stops the loop and logs when the aggregate deadline is exceeded (#824)' do
        allow(scanner).to receive(:aggregate_timeout).and_return(0)
        expect(scanner).not_to receive(:run_command)
        expect(Penetrator.logger).to receive(:warn).with(/Aggregate timeout 0s reached.*skipping 2 remaining/)
        result = scanner.run
        expect(result[:success]).to be true
        expect(result[:findings]).to eq([])
      end
    end

    context 'with an output path / config containing shell metacharacters (#824)' do
      it 'shell-escapes the output-dir path' do
        weird = Pathname.new('/tmp/out dir;$(id)')
        allow(scanner).to receive(:output_dir).and_return(weird)
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include("--output-dir=#{Shellwords.escape(weird.join('sqlmap_output').to_s)}")
          expect(cmd).not_to include('--output-dir=/tmp/out dir;$(id)')
          success_result
        end
        scanner.run
      end

      it 'coerces a non-integer level, dropping any injected suffix' do
        scanner_cfg = described_class.new(scan, { level: '2; rm -rf /', timeout: 600 })
        allow(scanner_cfg).to receive(:run_command).and_return(success_result)
        allow(ResultParsers::SqlmapParser).to receive(:new).and_return(instance_double(ResultParsers::SqlmapParser, parse: []))
        expect(scanner_cfg).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('--level=2')
          expect(cmd).not_to include('rm -rf')
          success_result
        end
        scanner_cfg.run
      end
    end

    it 'parses results for each URL' do
      parsed = [{ source_tool: 'sqlmap', title: 'SQL Injection - boolean-based blind', severity: 'high' }]
      allow(ResultParsers::SqlmapParser).to receive(:new).and_return(instance_double(ResultParsers::SqlmapParser, parse: parsed))

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end
  end
end
