require 'sequel_helper'

RSpec.describe FindingNormalizer do
  subject(:normalizer) { described_class.new(scan) }

  let(:scan) { create(:scan) }

  describe '#normalize' do
    it 'generates fingerprints for all findings' do
      finding = create(:finding, scan:, title: 'XSS', url: 'https://example.com/search', source_tool: 'zap', cwe_id: 'CWE-79')

      normalizer.normalize
      finding.reload

      expect(finding.fingerprint).to be_present
      expect(finding.fingerprint).to match(/\A[0-9a-f]{64}\z/)
    end

    it 'marks duplicate findings with matching fingerprints' do
      # Create two findings that will produce the same normalized fingerprint
      finding1 = create(:finding, scan:,
                                  title: 'XSS Vulnerability', url: 'https://example.com/search',
                                  parameter: 'q', cwe_id: 'CWE-79', source_tool: 'zap',
                                  created_at: 1.minute.ago)
      finding2 = create(:finding, scan:,
                                  title: 'XSS Vulnerability', url: 'https://example.com/search',
                                  parameter: 'q', cwe_id: 'CWE-79', source_tool: 'nuclei')

      normalizer.normalize

      finding1.reload
      finding2.reload

      expect(finding1.duplicate).to be false
      expect(finding2.duplicate).to be true
    end

    it 'does not mark findings with different fingerprints as duplicates' do
      finding1 = create(:finding, scan:,
                                  title: 'XSS', url: 'https://example.com/page1',
                                  source_tool: 'zap', cwe_id: 'CWE-79')
      finding2 = create(:finding, scan:,
                                  title: 'SQL Injection', url: 'https://example.com/page2',
                                  source_tool: 'sqlmap', cwe_id: 'CWE-89')

      normalizer.normalize

      finding1.reload
      finding2.reload

      expect(finding1.duplicate).to be false
      expect(finding2.duplicate).to be false
    end

    it 'normalizes URLs by extracting host and path' do
      # The normalizer generates fingerprints from title, normalized URL (host+path),
      # parameter, and cwe_id. The model's before_validation also regenerates fingerprints
      # using source_tool + title + url + parameter + cwe_id.
      # Use the same source_tool so the model callback produces matching fingerprints too.
      finding1 = create(:finding, scan:,
                                  title: 'XSS', url: 'https://example.com/search?q=test',
                                  parameter: nil, cwe_id: 'CWE-79', source_tool: 'zap',
                                  created_at: 1.minute.ago)
      finding2 = create(:finding, scan:,
                                  title: 'XSS', url: 'https://example.com/search?q=other',
                                  parameter: nil, cwe_id: 'CWE-79', source_tool: 'zap')

      normalizer.normalize

      finding1.reload
      finding2.reload

      # The normalizer's fingerprint (host+path without query) matches for both,
      # marking finding2 as duplicate. Then the model callback regenerates using
      # the full URL, so the final stored fingerprints differ -- but the duplicate
      # flag remains set from the normalizer's pass.
      expect(finding2.duplicate).to be true
    end

    it 'handles findings with nil URLs gracefully' do
      finding = create(:finding, scan:,
                                 title: 'Server Info', url: nil,
                                 source_tool: 'nikto', cwe_id: nil)

      expect { normalizer.normalize }.not_to raise_error

      finding.reload
      expect(finding.fingerprint).to be_present
    end

    it 'logs the number of duplicates found' do
      create(:finding, scan:,
                       title: 'XSS', url: 'https://example.com/search',
                       parameter: 'q', cwe_id: 'CWE-79', source_tool: 'zap',
                       created_at: 1.minute.ago)
      create(:finding, scan:,
                       title: 'XSS', url: 'https://example.com/search',
                       parameter: 'q', cwe_id: 'CWE-79', source_tool: 'nuclei')

      expect(Penetrator.logger).to receive(:info).with(/Marked 1 duplicate findings/)

      normalizer.normalize
    end
  end
end
