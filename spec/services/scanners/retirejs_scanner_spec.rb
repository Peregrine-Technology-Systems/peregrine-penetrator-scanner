require 'sequel_helper'

RSpec.describe Scanners::RetirejsScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it { expect(scanner.tool_name).to eq('retirejs') }
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(scanner).to receive(:fetch_target_js)
      allow(ResultParsers::RetirejsParser).to receive(:new)
        .and_return(instance_double(ResultParsers::RetirejsParser, parse: []))
    end

    it 'fetches JS before scanning (fetch-then-scan shape)' do
      expect(scanner).to receive(:fetch_target_js).once
      scanner.run
    end

    it 'passes the target URL to the parser' do
      parsed = [{ source_tool: 'retirejs', severity: 'medium', title: 'XSS' }]
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("retire_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::RetirejsParser).to receive(:new)
        .with(output_file, url).and_return(instance_double(ResultParsers::RetirejsParser, parse: parsed))
      result = scanner.run
      expect(result[:findings]).to eq(parsed)
    end

    it 'builds a retire command with --path and --outputformat json' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('retire')
        expect(cmd).to include('--path')
        expect(cmd).to include('--outputformat json')
        success_result
      end
      scanner.run
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://a.com', 'https://b.com'].to_json) }

      it 'runs retire once per URL' do
        expect(scanner).to receive(:fetch_target_js).twice
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end
  end

  describe '#fetch_target_js (private)' do
    it 'creates the js dir and runs wget' do
      js_dir = scanner.send(:output_dir).join('js_test')
      allow(scanner).to receive(:run_command).and_return(success_result)
      scanner.send(:fetch_target_js, 'https://example.com', js_dir)
      expect(js_dir).to be_directory
    end

    it 'rescues and logs on command failure' do
      js_dir = scanner.send(:output_dir).join('js_test2')
      allow(scanner).to receive(:run_command).and_raise(StandardError, 'timeout')
      expect { scanner.send(:fetch_target_js, 'https://example.com', js_dir) }.not_to raise_error
    end
  end
end
