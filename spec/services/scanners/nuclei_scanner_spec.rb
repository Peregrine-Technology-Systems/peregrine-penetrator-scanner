require 'rails_helper'

RSpec.describe Scanners::NucleiScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { timeout: 600 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_status) { instance_double(Process::Status, exitstatus: 0, success?: true) }

  describe '#tool_name' do
    it 'returns nuclei' do
      expect(scanner.tool_name).to eq('nuclei')
    end
  end

  describe '#run' do
    before do
      allow(Open3).to receive(:capture3).and_return(['', '', success_status])
      allow(ResultParsers::NucleiParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'writes target URLs to a file' do
      scanner.run
      urls_file = scanner.send(:output_dir).join('urls.txt')
      expect(File.read(urls_file)).to eq('https://example.com')
    end

    it 'builds the correct nuclei command' do
      expect(Open3).to receive(:capture3) do |cmd, **_opts|
        expect(cmd).to include('nuclei -l')
        expect(cmd).to include('-jsonl')
        expect(cmd).to include('-silent')
        ['', '', success_status]
      end

      scanner.run
    end

    context 'with severity filter' do
      let(:tool_config) { { severity_filter: 'critical,high', timeout: 600 } }

      it 'includes severity flag' do
        expect(Open3).to receive(:capture3) do |cmd, **_opts|
          expect(cmd).to include('-severity critical,high')
          ['', '', success_status]
        end

        scanner.run
      end
    end

    context 'with custom templates' do
      let(:tool_config) { { templates: ['/path/to/template.yaml'], timeout: 600 } }

      it 'includes template flags' do
        expect(Open3).to receive(:capture3) do |cmd, **_opts|
          expect(cmd).to include('-t /path/to/template.yaml')
          ['', '', success_status]
        end

        scanner.run
      end
    end

    it 'parses results and returns findings' do
      parsed = [{ source_tool: 'nuclei', title: 'CVE-2021-1234', severity: 'critical' }]
      output_file = scanner.send(:output_dir).join('nuclei_results.jsonl')
      FileUtils.touch(output_file)
      allow(ResultParsers::NucleiParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::NucleiParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end

    it 'always returns success even if command fails' do
      failure_status = instance_double(Process::Status, exitstatus: 1, success?: false)
      allow(Open3).to receive(:capture3).and_return(['', '', failure_status])

      result = scanner.run
      expect(result[:success]).to be true
    end
  end
end
