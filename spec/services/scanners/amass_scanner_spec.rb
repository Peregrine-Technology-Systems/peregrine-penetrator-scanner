require 'sequel_helper'

RSpec.describe Scanners::AmassScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 600 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it { expect(scanner.tool_name).to eq('amass') }
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::AmassParser).to receive(:new)
        .and_return(instance_double(ResultParsers::AmassParser, parse: { discovered_urls: [] }))
    end

    it 'returns discovered_urls (not findings)' do
      result = scanner.run
      expect(result).to have_key(:discovered_urls)
    end

    it 'returns empty findings (amass is a subdomain scanner, not vuln scanner)' do
      result = scanner.run
      expect(result[:findings]).to eq([])
    end

    it 'runs amass enum then amass subs (two-step v5 pattern)' do
      enum_called = false
      subs_called = false
      allow(scanner).to receive(:run_command) do |cmd, **_opts|
        enum_called = true if cmd.include?('amass enum')
        subs_called = true if cmd.include?('amass subs')
        success_result
      end
      scanner.run
      expect(enum_called).to be(true)
      expect(subs_called).to be(true)
    end

    it 'passes the subs output file to the parser' do
      urls = ['https://api.example.com']
      subs_output = scanner.send(:subs_output_file, 'example.com')
      FileUtils.touch(subs_output)
      allow(ResultParsers::AmassParser).to receive(:new)
        .with(subs_output).and_return(instance_double(ResultParsers::AmassParser, parse: { discovered_urls: urls }))
      result = scanner.run
      expect(result[:discovered_urls]).to eq(urls)
    end
  end
end
