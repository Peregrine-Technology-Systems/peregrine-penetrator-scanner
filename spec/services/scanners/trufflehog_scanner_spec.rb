require 'sequel_helper'

RSpec.describe Scanners::TrufflehogScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it { expect(scanner.tool_name).to eq('trufflehog') }
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(scanner).to receive(:fetch_target_files)
      allow(ResultParsers::TrufflehogParser).to receive(:new)
        .and_return(instance_double(ResultParsers::TrufflehogParser, parse: []))
    end

    it 'fetches target files before scanning (fetch-then-scan shape)' do
      expect(scanner).to receive(:fetch_target_files).once
      scanner.run
    end

    it 'passes the target URL to the parser' do
      parsed = [{ source_tool: 'trufflehog', severity: 'high', title: 'PrivateKey' }]
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("trufflehog_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::TrufflehogParser).to receive(:new)
        .with(output_file, url)
        .and_return(instance_double(ResultParsers::TrufflehogParser, parse: parsed))
      result = scanner.run
      expect(result[:findings]).to eq(parsed)
    end

    it 'builds a trufflehog command with --json and filesystem subcommand' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('trufflehog')
        expect(cmd).to include('filesystem')
        expect(cmd).to include('--json')
        success_result
      end
      scanner.run
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://a.com', 'https://b.com'].to_json) }

      it 'runs trufflehog once per URL' do
        expect(scanner).to receive(:fetch_target_files).twice
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end
  end

  describe '#fetch_target_files (private)' do
    it 'creates the files dir and runs wget' do
      files_dir = scanner.send(:output_dir).join('files_test')
      allow(scanner).to receive(:run_command).and_return(success_result)
      scanner.send(:fetch_target_files, 'https://example.com', files_dir)
      expect(files_dir).to be_directory
    end

    it 'rescues and logs on command failure' do
      files_dir = scanner.send(:output_dir).join('files_test2')
      allow(scanner).to receive(:run_command).and_raise(StandardError, 'timeout')
      expect { scanner.send(:fetch_target_files, 'https://example.com', files_dir) }.not_to raise_error
    end
  end
end
