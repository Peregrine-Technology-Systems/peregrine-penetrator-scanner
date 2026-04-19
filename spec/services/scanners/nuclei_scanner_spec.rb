require 'sequel_helper'

RSpec.describe Scanners::NucleiScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { timeout: 600 } }
  let(:scanner) { described_class.new(scan, tool_config) }
  let(:success_result) { { stdout: '', stderr: '', exit_code: 0, success: true } }

  describe '#tool_name' do
    it 'returns nuclei' do
      expect(scanner.tool_name).to eq('nuclei')
    end
  end

  describe '#run' do
    before do
      allow(scanner).to receive(:run_command).and_return(success_result)
      allow(ResultParsers::NucleiParser).to receive(:new).and_return(instance_double(ResultParsers::NucleiParser, parse: []))
    end

    it 'writes target URLs to a file' do
      scanner.run
      urls_file = scanner.send(:output_dir).join('urls.txt')
      expect(File.read(urls_file)).to eq('https://example.com')
    end

    it 'builds the correct nuclei command' do
      expect(scanner).to receive(:run_command) do |cmd, **_opts|
        expect(cmd).to include('nuclei -l')
        expect(cmd).to include('-jsonl')
        expect(cmd).to include('-silent')
        success_result
      end

      scanner.run
    end

    context 'with severity filter' do
      let(:tool_config) { { severity_filter: 'critical,high', timeout: 600 } }

      it 'includes severity flag' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-severity critical,high')
          success_result
        end

        scanner.run
      end
    end

    context 'with custom templates' do
      let(:tool_config) { { templates: ['/path/to/template.yaml'], timeout: 600 } }

      it 'includes template flags' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-t /path/to/template.yaml')
          success_result
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
      failure_result = { stdout: '', stderr: '', exit_code: 1, success: false }
      allow(scanner).to receive(:run_command).and_return(failure_result)

      result = scanner.run
      expect(result[:success]).to be true
    end

    context 'with auto_templates enabled and WordPress detected' do
      let(:tool_config) { { auto_templates: true, timeout: 600 } }

      before do
        scan.summary = { 'cms_inventory' => { 'cms' => 'wordpress', 'confidence' => 0.9 } }
        scan.save_changes
      end

      it 'appends WordPress-specific Nuclei template paths' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).to include('-t http/technologies/wordpress/')
          expect(cmd).to include('-t http/cves/wordpress/')
          success_result
        end

        scanner.run
      end

      it 'merges auto templates with explicit templates without duplicates' do
        scanner = described_class.new(scan, auto_templates: true,
                                            templates: ['http/technologies/wordpress/', '/custom/t.yaml'],
                                            timeout: 600)
        allow(scanner).to receive(:run_command).and_return(success_result)
        allow(ResultParsers::NucleiParser).to receive(:new).and_return(
          instance_double(ResultParsers::NucleiParser, parse: [])
        )

        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd.scan('-t http/technologies/wordpress/').size).to eq(1)
          expect(cmd).to include('-t /custom/t.yaml')
          success_result
        end

        scanner.run
      end
    end

    context 'with auto_templates enabled but no WordPress detected' do
      let(:tool_config) { { auto_templates: true, timeout: 600 } }

      it 'does not append any CMS template paths' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).not_to include('-t http/technologies/wordpress/')
          success_result
        end

        scanner.run
      end
    end

    context 'with auto_templates disabled (default) and WordPress detected' do
      let(:tool_config) { { timeout: 600 } }

      before do
        scan.summary = { 'cms_inventory' => { 'cms' => 'wordpress', 'confidence' => 0.9 } }
        scan.save_changes
      end

      it 'does not append CMS template paths' do
        expect(scanner).to receive(:run_command) do |cmd, **_opts|
          expect(cmd).not_to include('-t http/')
          success_result
        end

        scanner.run
      end
    end
  end
end
