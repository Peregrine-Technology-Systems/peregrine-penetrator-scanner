require 'digest'

class FindingNormalizer
  def initialize(scan)
    @scan = scan
  end

  def normalize
    findings = @scan.findings.order(:created_at)
    seen_fingerprints = Set.new

    findings.each do |finding|
      fingerprint = generate_fingerprint(finding)
      finding.update!(fingerprint:)

      if seen_fingerprints.include?(fingerprint)
        finding.update!(duplicate: true)
      else
        seen_fingerprints.add(fingerprint)
      end
    end

    duplicate_count = @scan.findings.where(duplicate: true).count
    Penetrator.logger.info("[FindingNormalizer] Marked #{duplicate_count} duplicate findings")
  end

  private

  def generate_fingerprint(finding)
    components = [
      finding.title&.downcase&.strip,
      normalize_url(finding.url),
      finding.parameter&.downcase&.strip,
      finding.cwe_id
    ].compact.join(':')

    Digest::SHA256.hexdigest(components)
  end

  def normalize_url(url)
    return nil unless url

    uri = URI.parse(url)
    "#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    url
  end
end
