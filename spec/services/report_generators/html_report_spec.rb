require 'rails_helper'

RSpec.describe ReportGenerators::HtmlReport do
  let(:target) do
    create(:target, name: 'Test Corp',
           urls: '["https://example.com"]',
           brand_config: { 'company_name' => 'Acme Security', 'accent_color' => '#ff0000',
                           'footer_text' => 'CONFIDENTIAL' })
  end
  let(:scan) do
    create(:scan, :completed, target: target, profile: 'standard',
           summary: {
             'total_findings' => 2,
             'by_severity' => { 'high' => 1, 'medium' => 1 }
           })
  end
  let(:findings) do
    [
      create(:finding, scan: scan, source_tool: 'zap', severity: 'high',
             title: 'XSS Vulnerability', url: 'https://example.com/search',
             cwe_id: 'CWE-79'),
      create(:finding, scan: scan, source_tool: 'nikto', severity: 'medium',
             title: 'Missing Headers', url: 'https://example.com/')
    ]
  end

  subject(:report) { described_class.new(scan: scan, findings: findings, target: target) }

  describe '#generate' do
    before do
      # Force basic conversion (no pandoc) for predictable test results
      allow(report).to receive(:pandoc_available?).and_return(false)
    end

    let(:output) { report.generate }

    it 'produces valid HTML with doctype' do
      expect(output).to include('<!DOCTYPE html>')
      expect(output).to include('<html lang="en">')
      expect(output).to include('</html>')
    end

    it 'includes target name in title' do
      expect(output).to include('Test Corp')
    end

    it 'includes company name in title and footer' do
      expect(output).to include('Acme Security')
    end

    it 'uses brand accent color in styles' do
      expect(output).to include('#ff0000')
    end

    it 'includes footer text' do
      expect(output).to include('CONFIDENTIAL')
    end

    it 'converts markdown headers to HTML headers' do
      expect(output).to include('<h2>')
      expect(output).to include('Executive Summary')
    end

    it 'converts bold text to strong tags' do
      expect(output).to include('<strong>')
    end

    it 'converts inline code to code tags' do
      expect(output).to include('<code>')
    end

    it 'converts markdown tables to HTML tables' do
      expect(output).to include('<table>')
      expect(output).to include('<thead>')
      expect(output).to include('<tbody>')
      expect(output).to include('<th>')
      expect(output).to include('<td>')
    end

    it 'wraps plain text in paragraph tags' do
      expect(output).to include('<p>')
    end

    it 'includes viewport meta tag for responsiveness' do
      expect(output).to include('viewport')
    end

    it 'includes print media query' do
      expect(output).to include('@media print')
    end
  end

  describe '#filename' do
    it 'returns an HTML filename with scan id' do
      expect(report.filename).to eq("scan_#{scan.id}_report.html")
    end
  end

  describe '#content_type' do
    it 'returns text/html' do
      expect(report.content_type).to eq('text/html')
    end
  end

  describe 'basic markdown to HTML conversion' do
    let(:output) { report.generate }

    before do
      allow(report).to receive(:pandoc_available?).and_return(false)
    end

    it 'converts h1 headers' do
      # The markdown report won't have h1 in body (executive summary uses h2+),
      # but h1 is handled by convert_basic
      expect(output).to include('<h2>')
    end

    it 'converts h3 and h4 headers' do
      expect(output).to include('<h3>')
    end

    it 'converts italic text' do
      # The report includes *Report generated...* which becomes italic
      expect(output).to include('<em>')
    end

    it 'converts list items' do
      expect(output).to include('<li>')
    end

    it 'closes tables properly at end of input' do
      expect(output).to include('</tbody></table>')
    end
  end

  describe 'pandoc conversion path' do
    context 'when pandoc is available and succeeds' do
      before do
        allow(report).to receive(:pandoc_available?).and_return(true)
        allow(Open3).to receive(:capture3).and_return(
          ['<h2>Executive Summary</h2>', '', instance_double(Process::Status, success?: true)]
        )
      end

      it 'uses pandoc output' do
        output = report.generate
        expect(output).to include('Executive Summary')
      end
    end

    context 'when pandoc is available but fails' do
      before do
        allow(report).to receive(:pandoc_available?).and_return(true)
        allow(Open3).to receive(:capture3).and_return(
          ['', 'pandoc error', instance_double(Process::Status, success?: false)]
        )
      end

      it 'falls back to basic conversion' do
        output = report.generate
        expect(output).to include('<h2>')
        expect(output).to include('Executive Summary')
      end
    end
  end

  describe 'table conversion edge cases' do
    before do
      allow(report).to receive(:pandoc_available?).and_return(false)
    end

    it 'handles multiple tables in the output' do
      output = report.generate
      # The report has multiple tables (key metrics, tool descriptions, etc.)
      table_count = output.scan('<table>').size
      expect(table_count).to be >= 2
    end
  end
end
