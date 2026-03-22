# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Finding do
  describe 'validations' do
    it 'requires source_tool, title, severity, fingerprint' do
      finding = Finding.new(scan_id: create(:scan).id)
      expect(finding.valid?).to be false
      expect(finding.errors.on(:source_tool)).not_to be_nil
      expect(finding.errors.on(:title)).not_to be_nil
      expect(finding.errors.on(:severity)).not_to be_nil
    end

    it 'validates severity inclusion' do
      finding = build(:finding, severity: 'invalid')
      expect(finding.valid?).to be false
    end

    it 'enforces fingerprint uniqueness within scan' do
      scan = create(:scan)
      attrs = { scan: scan, source_tool: 'zap', title: 'XSS', url: 'https://example.com',
                parameter: 'q', cwe_id: 'CWE-79' }
      create(:finding, **attrs)
      expect {
        create(:finding, **attrs)
      }.to raise_error(Sequel::ValidationFailed, /fingerprint/)
    end

    it 'allows same composite key in different scans' do
      attrs = { source_tool: 'zap', title: 'XSS', url: 'https://example.com',
                parameter: 'q', cwe_id: 'CWE-79' }
      f1 = create(:finding, **attrs)
      f2 = create(:finding, **attrs)
      expect(f1.fingerprint).to eq(f2.fingerprint)
      expect(f1.scan_id).not_to eq(f2.scan_id)
    end
  end

  describe '#before_validation' do
    it 'generates fingerprint from composite key' do
      finding = build(:finding, source_tool: 'zap', title: 'XSS', url: 'https://example.com',
                                parameter: 'q', cwe_id: 'CWE-79', fingerprint: nil)
      finding.valid?
      expect(finding.fingerprint).to eq(
        Digest::SHA256.hexdigest('zap:XSS:https://example.com:q:CWE-79')
      )
    end
  end

  describe '.by_severity' do
    it 'orders by severity priority' do
      scan = create(:scan)
      create(:finding, scan: scan, severity: 'low')
      create(:finding, scan: scan, severity: 'critical')
      create(:finding, scan: scan, severity: 'medium')

      titles = Finding.by_severity.select_map(:severity)
      expect(titles).to eq(%w[critical medium low])
    end
  end

  describe '.non_duplicate' do
    it 'excludes duplicates' do
      scan = create(:scan)
      create(:finding, scan: scan, duplicate: false)
      create(:finding, scan: scan, duplicate: true)
      expect(Finding.non_duplicate.count).to eq(1)
    end
  end

  describe '.by_tool' do
    it 'filters by source tool' do
      scan = create(:scan)
      create(:finding, scan: scan, source_tool: 'zap')
      create(:finding, scan: scan, source_tool: 'nuclei')
      expect(Finding.by_tool('zap').count).to eq(1)
    end
  end
end
