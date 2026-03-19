require 'rails_helper'

RSpec.describe ReportGenerators::PdfReport do
  subject(:report) { described_class.new(scan:, findings:, target:) }

  let(:target) do
    create(:target, name: 'Test Corp',
                    urls: '["https://example.com"]',
                    brand_config: { 'company_name' => 'Acme Security' })
  end
  let(:scan) do
    create(:scan, :completed, target:, profile: 'standard',
                              summary: {
                                'total_findings' => 2,
                                'by_severity' => { 'critical' => 1, 'high' => 1 }
                              })
  end
  let(:findings) do
    [
      create(:finding, scan:, source_tool: 'zap', severity: 'critical',
                       title: 'SQL Injection', url: 'https://example.com/login'),
      create(:finding, scan:, source_tool: 'nuclei', severity: 'high',
                       title: 'CVE-2024-1234', url: 'https://example.com/')
    ]
  end

  describe '#generate' do
    context 'when pandoc succeeds' do
      it 'returns PDF binary content' do
        pdf_content = 'fake-pdf-binary-content'
        allow(Open3).to receive(:capture3) do |_cmd, chdir:|
          # Write a fake PDF file to the expected location
          pdf_path = File.join(chdir, 'report.pdf')
          File.write(pdf_path, pdf_content)
          ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
        end

        result = report.generate
        expect(result).to eq(pdf_content)
      end
    end

    context 'when pandoc fails' do
      it 'falls back to markdown content' do
        allow(Open3).to receive(:capture3).and_return(
          ['', 'xelatex not found', instance_double(Process::Status, success?: false, exitstatus: 1)]
        )

        result = report.generate
        expect(result).to include('## Executive Summary')
      end

      it 'logs a warning' do
        allow(Open3).to receive(:capture3).and_return(
          ['', 'xelatex error', instance_double(Process::Status, success?: false, exitstatus: 1)]
        )

        expect(Rails.logger).to receive(:warn).with(/pandoc failed/)
        report.generate
      end
    end

    context 'when an exception is raised' do
      it 'falls back to markdown content' do
        allow(Open3).to receive(:capture3).and_raise(StandardError, 'unexpected error')

        result = report.generate
        expect(result).to include('## Executive Summary')
      end

      it 'logs the exception' do
        allow(Open3).to receive(:capture3).and_raise(StandardError, 'disk full')

        expect(Rails.logger).to receive(:warn).with(/PDF generation failed.*disk full/)
        report.generate
      end
    end

    it 'creates temporary directory for report generation' do
      allow(Open3).to receive(:capture3).and_return(
        ['', '', instance_double(Process::Status, success?: false, exitstatus: 1)]
      )

      report.generate
      expect(Rails.root.join('tmp', 'reports', scan.id).directory?).to be true
    end

    it 'writes markdown content to temporary file' do
      allow(Open3).to receive(:capture3).and_return(
        ['', '', instance_double(Process::Status, success?: false, exitstatus: 1)]
      )

      report.generate
      md_path = Rails.root.join('tmp', 'reports', scan.id, 'report.md')
      expect(File.exist?(md_path)).to be true
      expect(File.read(md_path)).to include('Executive Summary')
    end
  end

  describe '#filename' do
    it 'returns a PDF filename with scan id' do
      expect(report.filename).to eq("scan_#{scan.id}_report.pdf")
    end
  end

  describe '#content_type' do
    it 'returns application/pdf' do
      expect(report.content_type).to eq('application/pdf')
    end
  end

  describe 'pandoc command construction' do
    it 'includes xelatex engine and template arguments' do
      allow(Open3).to receive(:capture3) do |cmd, **_opts|
        # shelljoin escapes = signs, so check for the unescaped content
        expect(cmd).to include('xelatex')
        expect(cmd).to include('pentest_report.latex')
        expect(cmd).to include('title')
        expect(cmd).to include('sev_critical')
        expect(cmd).to include('sev_high')
        ['', '', instance_double(Process::Status, success?: false, exitstatus: 1)]
      end

      report.generate
    end
  end
end
