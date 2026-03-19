require 'rails_helper'

RSpec.describe Scanners::FfufScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target: target) }
  let(:tool_config) { { wordlist: '/usr/share/seclists/common.txt', threads: 20, timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns ffuf' do
      expect(scanner.tool_name).to eq('ffuf')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::FfufParser).to receive_message_chain(:new, :parse).and_return([])
    end

    it 'builds the correct ffuf command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('ffuf -u')
        expect(cmd).to include('/FUZZ')
        expect(cmd).to include('-w /usr/share/seclists/common.txt')
        expect(cmd).to include('-of json')
        expect(cmd).to include('-mc 200,201,301,302,403')
        expect(cmd).to include('-t 20')
        expect(cmd).to include('-s')
        success_result
      end

      scanner.run
    end

    context 'with default wordlist and threads' do
      let(:tool_config) { { timeout: 300 } }

      it 'uses defaults' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-w /usr/share/seclists/Discovery/Web-Content/common.txt')
          expect(cmd).to include('-t 40')
          success_result
        end

        scanner.run
      end
    end

    context 'with extensions' do
      let(:tool_config) { { extensions: '.php,.html', timeout: 300 } }

      it 'includes extensions flag' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-e .php,.html')
          success_result
        end

        scanner.run
      end
    end

    it 'returns discovered_urls from findings' do
      parsed = [
        { source_tool: 'ffuf', url: 'https://example.com/admin', severity: 'info' },
        { source_tool: 'ffuf', url: 'https://example.com/login', severity: 'info' }
      ]
      # Create the output file so parse_results finds it
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("ffuf_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::FfufParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::FfufParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:success]).to be true
      expect(result[:discovered_urls]).to contain_exactly('https://example.com/admin', 'https://example.com/login')
    end

    it 'deduplicates discovered URLs' do
      parsed = [
        { source_tool: 'ffuf', url: 'https://example.com/admin', severity: 'info' },
        { source_tool: 'ffuf', url: 'https://example.com/admin', severity: 'info' }
      ]
      url = 'https://example.com'
      output_file = scanner.send(:output_dir).join("ffuf_#{Digest::MD5.hexdigest(url)}.json")
      FileUtils.touch(output_file)
      allow(ResultParsers::FfufParser).to receive(:new).with(output_file).and_return(
        instance_double(ResultParsers::FfufParser, parse: parsed)
      )

      result = scanner.run
      expect(result[:discovered_urls]).to eq(['https://example.com/admin'])
    end

    context 'with multiple target URLs' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://test.com'].to_json) }

      it 'runs ffuf for each URL' do
        expect(scanner).to receive(:run_command).twice.and_return(success_result)
        scanner.run
      end
    end
  end
end
