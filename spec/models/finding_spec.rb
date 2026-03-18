require 'rails_helper'

RSpec.describe Finding do
  describe 'validations' do
    subject { build(:finding) }

    it { is_expected.to validate_presence_of(:source_tool) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:severity) }
    it { is_expected.to validate_inclusion_of(:severity).in_array(%w[critical high medium low info]) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:scan) }
  end

  describe 'fingerprint generation' do
    it 'auto-generates a fingerprint before validation' do
      finding = build(:finding, fingerprint: nil, source_tool: 'zap', title: 'XSS', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79')
      finding.valid?

      expected = Digest::SHA256.hexdigest('zap:XSS:https://example.com:q:CWE-79')
      expect(finding.fingerprint).to eq(expected)
    end

    it 'generates deterministic fingerprints for same inputs' do
      attrs = { source_tool: 'zap', title: 'XSS', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79' }
      finding1 = build(:finding, **attrs, fingerprint: nil)
      finding2 = build(:finding, **attrs, fingerprint: nil)

      finding1.valid?
      finding2.valid?

      expect(finding1.fingerprint).to eq(finding2.fingerprint)
    end

    it 'generates different fingerprints for different inputs' do
      finding1 = build(:finding, fingerprint: nil, source_tool: 'zap', title: 'XSS', url: 'https://a.com')
      finding2 = build(:finding, fingerprint: nil, source_tool: 'nuclei', title: 'SQLi', url: 'https://b.com')

      finding1.valid?
      finding2.valid?

      expect(finding1.fingerprint).not_to eq(finding2.fingerprint)
    end
  end

  describe 'uniqueness' do
    it 'enforces fingerprint uniqueness within the same scan' do
      scan = create(:scan)
      # Two findings with identical attributes will get the same auto-generated fingerprint
      create(:finding, scan:, source_tool: 'zap', title: 'Test', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79', severity: 'high')

      duplicate = build(:finding, scan:, source_tool: 'zap', title: 'Test', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79', severity: 'high')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:fingerprint]).to include('has already been taken')
    end

    it 'allows same fingerprint across different scans' do
      scan1 = create(:scan)
      scan2 = create(:scan)
      create(:finding, scan: scan1, source_tool: 'zap', title: 'Test', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79', severity: 'high')

      finding2 = build(:finding, scan: scan2, source_tool: 'zap', title: 'Test', url: 'https://example.com', parameter: 'q', cwe_id: 'CWE-79', severity: 'high')

      expect(finding2).to be_valid
    end
  end

  describe 'scopes' do
    let(:scan) { create(:scan) }

    describe '.by_severity' do
      it 'orders findings by severity priority (critical first)' do
        info = create(:finding, scan:, severity: 'info', source_tool: 'zap', title: 'Info 1', url: 'https://a.com/1')
        critical = create(:finding, scan:, severity: 'critical', source_tool: 'zap', title: 'Critical 1', url: 'https://a.com/2')
        create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'High 1', url: 'https://a.com/3')

        ordered = scan.findings.by_severity

        expect(ordered.first).to eq(critical)
        expect(ordered.last).to eq(info)
      end
    end

    describe '.non_duplicate' do
      it 'excludes duplicate findings' do
        original = create(:finding, scan:, duplicate: false, source_tool: 'zap', title: 'XSS', url: 'https://a.com/1')
        create(:finding, scan:, duplicate: true, source_tool: 'zap', title: 'XSS Dup', url: 'https://a.com/2')

        expect(scan.findings.non_duplicate).to eq([original])
      end
    end

    describe '.by_tool' do
      it 'filters findings by source tool' do
        zap_finding = create(:finding, scan:, source_tool: 'zap', title: 'ZAP Finding', url: 'https://a.com/1')
        create(:finding, scan:, source_tool: 'nuclei', title: 'Nuclei Finding', url: 'https://a.com/2')

        expect(scan.findings.by_tool('zap')).to eq([zap_finding])
      end
    end
  end

  describe 'serialized attributes' do
    it 'serializes evidence as JSON' do
      evidence = { 'description' => 'XSS found', 'payload' => '<script>alert(1)</script>' }
      finding = create(:finding, evidence:)
      finding.reload

      expect(finding.evidence).to eq(evidence)
    end

    it 'serializes ai_assessment as JSON' do
      assessment = { 'confidence' => 0.95, 'recommendation' => 'Fix immediately' }
      finding = create(:finding, ai_assessment: assessment)
      finding.reload

      expect(finding.ai_assessment).to eq(assessment)
    end
  end
end
