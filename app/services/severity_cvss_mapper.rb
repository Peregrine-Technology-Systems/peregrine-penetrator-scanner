# frozen_string_literal: true

class SeverityCvssMapper
  SEVERITY_TO_CVSS = {
    'critical' => { score: 9.5, vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:N' },
    'high' => { score: 7.5, vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N' },
    'medium' => { score: 5.0, vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:L/I:L/A:N' },
    'low' => { score: 2.5, vector: 'CVSS:3.1/AV:N/AC:H/PR:L/UI:R/S:U/C:L/I:N/A:N' },
    'info' => { score: 0.0, vector: nil }
  }.freeze

  def self.enrich(finding)
    return if finding.cvss_score

    mapping = SEVERITY_TO_CVSS[finding.severity] || SEVERITY_TO_CVSS['info']
    finding.update(cvss_score: mapping[:score], cvss_vector: mapping[:vector])
  end
end
