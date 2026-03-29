require 'sequel_helper'

RSpec.describe SeverityCvssMapper do
  let(:scan) { create(:scan, :running) }

  describe '.enrich' do
    it 'maps high severity to CVSS 7.5' do
      finding = create(:finding, scan:, source_tool: 'zap', severity: 'high', title: 'XSS')

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(7.5)
      expect(finding.cvss_vector).to start_with('CVSS:3.1/')
    end

    it 'maps medium severity to CVSS 5.0' do
      finding = create(:finding, scan:, source_tool: 'zap', severity: 'medium', title: 'Missing Header')

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(5.0)
    end

    it 'maps critical severity to CVSS 9.5' do
      finding = create(:finding, scan:, source_tool: 'nuclei', severity: 'critical', title: 'RCE')

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(9.5)
    end

    it 'maps info severity to CVSS 0.0 with nil vector' do
      finding = create(:finding, scan:, source_tool: 'zap', severity: 'info', title: 'Info')

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(0.0)
      expect(finding.cvss_vector).to be_nil
    end

    it 'does not overwrite existing cvss_score' do
      finding = create(:finding, scan:, source_tool: 'nuclei', severity: 'high',
                                 title: 'CVE Finding', cvss_score: 9.8)

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(9.8)
    end

    it 'works for any source tool' do
      finding = create(:finding, scan:, source_tool: 'nikto', severity: 'low', title: 'Outdated Server')

      described_class.enrich(finding)
      finding.reload

      expect(finding.cvss_score).to eq(2.5)
    end
  end
end
