FactoryBot.define do
  # Findings now carry the probe output contract document in `data` (#971). The
  # flat web fields below are kept as factory conveniences (specs still pass
  # url:/cwe_id:/cve_id:/cvss_score:) and are folded into the contract document so
  # the exporter — which reads `data` — emits them. `fingerprint` is left to the
  # model (computed from the contract document).
  factory :finding do
    association :scan, strategy: :create
    source_tool { %w[zap nuclei sqlmap ffuf nikto].sample }
    severity { %w[critical high medium low info].sample }
    title { Faker::Hacker.say_something_smart }
    finding_type { 'vulnerability' }
    duplicate { false }

    url { Faker::Internet.url }
    parameter { nil }
    cwe_id { "CWE-#{rand(1..1000)}" }
    cve_id { nil }
    cvss_score { nil }
    cvss_vector { nil }
    epss_score { nil }
    kev_known_exploited { nil }
    evidence { { 'description' => Faker::Lorem.sentence } }

    data do
      scores = { 'cvss_score' => cvss_score, 'cvss_vector' => cvss_vector, 'epss_score' => epss_score }.compact
      {
        'source_tool' => source_tool, 'probe' => 'web-dast', 'finding_type' => finding_type,
        'severity' => severity, 'title' => title,
        'location' => { 'kind' => 'web', 'url' => url, 'parameter' => parameter }.compact,
        'identifiers' => [
          cwe_id && { 'type' => 'cwe', 'value' => cwe_id },
          cve_id && { 'type' => 'cve', 'value' => cve_id }
        ].compact,
        'scores' => (scores.empty? ? nil : scores),
        'evidence' => evidence
      }.compact
    end
  end
end
