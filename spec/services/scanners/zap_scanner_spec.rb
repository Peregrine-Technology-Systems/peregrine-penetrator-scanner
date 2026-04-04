require 'sequel_helper'

RSpec.describe Scanners::ZapScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { mode: 'baseline', timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:command_results) do
    {
      success: { stdout: '', stderr: '', exit_code: 0, success: true },
      warning: { stdout: '', stderr: '', exit_code: 2, success: false },
      failure: { stdout: '', stderr: 'error occurred', exit_code: 1, success: false }
    }
  end

  describe '#tool_name' do
    it 'returns zap' do
      expect(scanner.tool_name).to eq('zap')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(command_results[:success])
      allow(ResultParsers::ZapParser).to receive(:new).and_return(instance_double(ResultParsers::ZapParser, parse: []))
    end

    it 'builds the correct baseline command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('zap-baseline.py')
        expect(cmd).to include('-t https://example.com')
        expect(cmd).to include('-J')
        expect(cmd).to include('-I')
        command_results[:success]
      end

      scanner.run
    end

    context 'with full mode' do
      let(:tool_config) { { mode: 'full', timeout: 300 } }

      it 'builds the full scan command' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('zap-full-scan.py')
          command_results[:success]
        end

        scanner.run
      end
    end

    context 'with api mode' do
      let(:tool_config) { { mode: 'api', timeout: 300 } }

      it 'builds the api scan command' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('zap-api-scan.py')
          command_results[:success]
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
      allow(scanner).to receive(:run_command).and_return(command_results[:warning])

      result = scanner.run
      expect(result[:success]).to be true
    end

    it 'treats exit code 1 as failure' do
      allow(scanner).to receive(:run_command).and_return(command_results[:failure])

      result = scanner.run
      expect(result[:success]).to be false
    end

    it 'parses results on success' do
      parsed_findings = [{ source_tool: 'zap', title: 'XSS', severity: 'high' }]
      # Stub ZAP wrk dir existence and FileUtils.cp to create the output file
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(anything).and_wrap_original do |m, path|
        path.to_s.include?('/zap/wrk/') ? true : m.call(path)
      end
      allow(FileUtils).to receive(:cp) do |_src, dest|
        FileUtils.touch(dest)
      end

      allow(ResultParsers::ZapParser).to receive(:new).and_return(
        instance_double(ResultParsers::ZapParser, parse: parsed_findings)
      )

      result = scanner.run
      expect(result[:findings]).to eq(parsed_findings)
    end

    it 'returns empty findings when output file does not exist' do
      result = scanner.run
      expect(result[:findings]).to eq([])
    end

    context 'with multiple target URLs on different hosts' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://test.com'].to_json) }

      it 'runs command once per unique origin' do
        expect(scanner).to receive(:run_command).twice.and_return(command_results[:success])
        scanner.run
      end
    end

    context 'with discovered URLs on the same host' do
      let(:target) do
        create(:target, urls: [
          'https://example.com',
          'https://example.com/admin',
          'https://example.com/.bash_history'
        ].to_json)
      end

      it 'deduplicates to one invocation per origin (ZAP spider handles paths)' do
        expect(scanner).to receive(:run_command).once.and_return(command_results[:success])
        scanner.run
      end

      it 'scans the origin URL, not individual paths' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-t https://example.com')
          expect(cmd).not_to include('/admin')
          expect(cmd).not_to include('/.bash_history')
          command_results[:success]
        end
        scanner.run
      end
    end
  end
end
