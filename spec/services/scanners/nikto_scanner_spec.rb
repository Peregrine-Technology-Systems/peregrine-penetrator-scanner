require 'rails_helper'

RSpec.describe Scanners::NiktoScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns nikto' do
      expect(scanner.tool_name).to eq('nikto')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::NiktoParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'builds the correct nikto command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('nikto -h')
        expect(cmd).to include('-Format json')
        expect(cmd).to include('-output')
        success_result
      end

      scanner.run
    end

    context 'with tuning option' do
      let(:tool_config) { { tuning: '123', timeout: 300 } }

      it 'includes tuning flag' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-Tuning 123')
          success_result
        end

        scanner.run
      end
    end

    it 'parses results and returns findings' do
      parsed = [{ source_tool: 'nikto', title: 'Server leaks version', severity: 'low' }]
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("nikto_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::NiktoParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::NiktoParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:findings]).to eq(parsed)
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://test.com'].to_json) }

      it 'runs nikto for each URL' do
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end

      it 'concatenates findings from all URLs' do
        parsed1 = [{ source_tool: 'nikto', title: 'Finding 1', severity: 'low' }]
        parsed2 = [{ source_tool: 'nikto', title: 'Finding 2', severity: 'medium' }]

        urls = ['https://example.com', 'https://test.com']
        urls.each do |url|
          output_file = scanner.send(:output_dir).join("nikto_#{Digest::MD5.hexdigest(url)}.json")
          FileUtils.touch(output_file)
        end

        call_count = 0
        allow(ResultParsers::NiktoParser).to receive(:new) do |_file|
          call_count += 1
          instance_double(ResultParsers::NiktoParser, parse: call_count == 1 ? parsed1 : parsed2)
        end

        result = scanner.run
        expect(result[:findings].length).to eq(2)
      end
    end
  end
end
