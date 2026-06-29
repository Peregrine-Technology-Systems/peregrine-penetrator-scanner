# frozen_string_literal: true

require 'digest'
require 'json'

# SyntheticCorpus — a deterministic, contract-conformant synthetic finding corpus.
#
# Purpose: bootstrap material for the downstream analysis service's Knowledge
# Loop, and the reference/contract-test fixture for `docs/probe_contract.md`.
#
# TWO LABELED SERIES:
#   * realistic — 100 well-formed findings across all nine reference probes,
#     ~half with a CVE and ~half without, with intra-set duplicates and findings
#     carrying multiple identifiers (to exercise dedup + lossless preservation).
#   * perturbed — 30 deliberately out-of-distribution findings, each labelled
#     `ext.synthetic.perturbation`, tagged `escalate` to mark the "exceeds the
#     deterministic DSL — novel / needs attention" class the Knowledge Loop must
#     learn the boundary of. NOT "garbage": the label is the training signal.
#
# IMPORTANT: this is SYNTHETIC bootstrap data, NOT ground truth. Its value is
# wiring / smoke / contract-test / cold-start. A loop trained on it risks
# learning the generator, not the world — replace with a real corpus as it
# accrues. Every finding is stamped `ext.synthetic.generated = true`.
#
# Deterministic by construction: fixed SEED, fixed base timestamp, derived ids.
# No SecureRandom / Time.now — re-running yields byte-identical output.
module SyntheticCorpus
  SEED = 20_260_629
  CONTRACT_VERSION = '2.0'
  BASE_TIME = Time.utc(2026, 6, 29, 12, 0, 0)
  REALISTIC_COUNT = 100
  PERTURBED_COUNT = 30
  SCAN_ID = '00000000-0000-0000-0000-0000000c0d05' # stable synthetic scan id

  SEVERITIES = %w[critical high medium low info].freeze

  # Per-probe templates: how each of the nine reference probes maps onto the
  # contract (see docs/probe_contract.md §5). `cve:` marks whether a variant
  # naturally carries an official identifier.
  PROBES = [
    { probe: 'web-dast', tool: 'zap', type: 'vulnerability', kind: 'web',
      checks: %w[40012 40018 10202 90022], cve: false,
      titles: ['Reflected XSS', 'SQL Injection', 'Anti-CSRF tokens absent', 'Application error disclosure'] },
    { probe: 'template-cve', tool: 'nuclei', type: 'vulnerability', kind: 'web',
      checks: %w[CVE-2021-44228 CVE-2022-22965 CVE-2023-23397 CVE-2017-5638], cve: true,
      titles: ['Log4j JNDI RCE', 'Spring4Shell RCE', 'Outlook NTLM leak', 'Struts2 OGNL RCE'] },
    { probe: 'injection', tool: 'sqlmap', type: 'vulnerability', kind: 'web',
      checks: %w[boolean-blind time-blind union-query error-based], cve: false,
      titles: ['Boolean-based blind SQLi', 'Time-based blind SQLi', 'UNION-query SQLi', 'Error-based SQLi'] },
    { probe: 'content-discovery', tool: 'ffuf', type: 'exposure', kind: 'web',
      checks: [], cve: false,
      titles: ['Discovered endpoint: /admin', 'Discovered endpoint: /.git', 'Discovered endpoint: /backup', 'Discovered endpoint: /api'] },
    { probe: 'server-misconfig', tool: 'nikto', type: 'misconfiguration', kind: 'web',
      checks: %w[OSVDB-3092 OSVDB-3268 OSVDB-877 OSVDB-630], cve: false,
      titles: ['/admin/ directory indexable', 'Directory listing enabled', 'TRACE method allowed', 'Server leaks version'] },
    { probe: 'tls', tool: 'testssl', type: 'misconfiguration', kind: 'network',
      checks: %w[BEAST POODLE heartbleed cert_expired RC4], cve: true,
      titles: ['BEAST attack possible', 'POODLE (SSLv3)', 'Heartbleed', 'Certificate expired', 'RC4 ciphers offered'] },
    { probe: 'sca', tool: 'retirejs', type: 'outdated-component', kind: 'package',
      checks: [], cve: true,
      titles: ['jQuery known vulnerabilities', 'AngularJS XSS', 'lodash prototype pollution', 'Bootstrap XSS'] },
    { probe: 'secrets', tool: 'trufflehog', type: 'secret', kind: 'file',
      checks: %w[AWS GitHub Stripe SlackWebhook], cve: false,
      titles: ['AWS credentials', 'GitHub token', 'Stripe API key', 'Slack webhook'] },
    { probe: 'asset-discovery', tool: 'amass', type: 'asset', kind: 'asset',
      checks: [], cve: false,
      titles: ['Subdomain discovered', 'Subdomain discovered', 'Subdomain discovered', 'Subdomain discovered'] }
  ].freeze

  module_function

  # Build the whole corpus as plain hashes (two envelopes + a manifest).
  def build
    rng = Random.new(SEED)
    realistic = build_realistic(rng)
    perturbed = build_perturbed(rng, realistic)
    {
      manifest: manifest(realistic, perturbed),
      realistic: envelope(realistic, series: 'realistic'),
      perturbed: envelope(perturbed, series: 'perturbed')
    }
  end

  # Write the corpus to disk (idempotent, deterministic).
  def write!(dir)
    require 'fileutils'
    FileUtils.mkdir_p(dir)
    corpus = build
    File.write(File.join(dir, 'manifest.json'), pretty(corpus[:manifest]))
    File.write(File.join(dir, 'realistic.json'), pretty(corpus[:realistic]))
    File.write(File.join(dir, 'perturbed.json'), pretty(corpus[:perturbed]))
    corpus
  end

  DUPLICATE_COUNT = 4

  def build_realistic(rng)
    unique = Array.new(REALISTIC_COUNT - DUPLICATE_COUNT) do |i|
      realistic_finding(PROBES[i % PROBES.length], i, rng)
    end
    # Append exact duplicates (same identity tuple ⇒ same fingerprint) to exercise dedup.
    dups = Array.new(DUPLICATE_COUNT) { |k| duplicate_of(unique[k * 7], (REALISTIC_COUNT - DUPLICATE_COUNT) + k) }
    unique + dups
  end

  def realistic_finding(spec, idx, rng)
    variant = idx % spec[:titles].length
    title = spec[:titles][variant]
    with_cve = spec[:cve] && rng.rand < 0.7
    sev = spec[:type] == 'asset' ? nil : SEVERITIES[rng.rand(with_cve ? 2 : SEVERITIES.length)]
    base = {
      id: uuid("realistic:#{idx}"),
      scan_id: SCAN_ID,
      detected_at: iso(idx),
      probe: spec[:probe],
      source_tool: spec[:tool],
      tool_check_id: spec[:checks][variant % [spec[:checks].length, 1].max],
      finding_type: spec[:type],
      severity: sev,
      severity_source: sev&.capitalize,
      confidence: %w[high medium low][rng.rand(3)],
      verified: spec[:tool] == 'trufflehog' ? (rng.rand < 0.5) : nil,
      title: title,
      description: "#{title} detected by #{spec[:tool]} on the authorized target.",
      location: location_for(spec, idx, variant, rng),
      identifiers: identifiers_for(spec, variant, with_cve, idx),
      component: component_for(spec, variant),
      scores: scores_for(spec, with_cve, rng),
      evidence: evidence_for(spec, variant),
      raw_ref: "gs://synthetic-corpus/raw/realistic/#{uuid("realistic:#{idx}")}.json",
      ext: { synthetic: { generated: true, series: 'realistic', index: idx } }
    }
    base[:fingerprint] = fingerprint(base)
    base.compact
  end

  def location_for(spec, idx, variant, _rng)
    case spec[:kind]
    when 'web'
      { kind: 'web', url: "https://target.example/#{%w[search login admin api][variant % 4]}",
        method: %w[GET POST][idx % 2], parameter: %w[q id user token][variant % 4] }
    when 'network'
      { kind: 'network', host: 'target.example', port: [443, 8443, 993][variant % 3], protocol: 'tls' }
    when 'package'
      { kind: 'package', name: %w[jquery angular lodash bootstrap][variant % 4],
        version: %w[1.7.1 1.5.0 4.17.4 3.3.7][variant % 4], ecosystem: 'npm' }
    when 'file'
      { kind: 'file', path: "config/#{%w[secrets.yml .env app.json deploy.sh][variant % 4]}",
        line: 10 + variant, commit: uuid("commit:#{idx}")[0, 12] }
    when 'asset'
      { kind: 'asset', domain: "sub#{idx}.target.example", ip: "203.0.113.#{idx % 254 + 1}", record_type: 'A' }
    end
  end

  def identifiers_for(spec, variant, with_cve, idx)
    ids = []
    if with_cve
      ids << { type: 'cve', value: spec[:tool] == 'nuclei' ? spec[:checks][variant % spec[:checks].length] : "CVE-2023-#{1000 + idx}" }
      # retirejs/testssl can carry MORE than one CVE — preserve all (lossless).
      ids << { type: 'cve', value: "CVE-2023-#{2000 + idx}" } if %w[retirejs testssl].include?(spec[:tool])
      ids << { type: 'ghsa', value: "GHSA-#{format('%04x', idx)}-aaaa-bbbb" } if spec[:tool] == 'retirejs'
    end
    ids << { type: 'cwe', value: cwe_for(spec) } if cwe_for(spec)
    ids
  end

  def cwe_for(spec)
    { 'zap' => 'CWE-79', 'nuclei' => 'CWE-94', 'sqlmap' => 'CWE-89', 'nikto' => 'CWE-16',
      'testssl' => 'CWE-326', 'retirejs' => 'CWE-1104' }[spec[:tool]]
  end

  def component_for(spec, variant)
    return nil unless spec[:kind] == 'package'

    { name: %w[jquery angular lodash bootstrap][variant % 4],
      version: %w[1.7.1 1.5.0 4.17.4 3.3.7][variant % 4], ecosystem: 'npm', cpe: nil }
  end

  def scores_for(spec, with_cve, rng)
    return nil unless spec[:tool] == 'nuclei' && with_cve

    { cvss_score: (rng.rand(40..98) / 10.0).round(1),
      cvss_vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H',
      epss_score: (rng.rand(0..9900) / 10_000.0).round(4) }
  end

  def evidence_for(spec, variant)
    case spec[:tool]
    when 'zap' then { request: 'GET /search?q=<script> HTTP/1.1', response: 'HTTP/1.1 200', matcher: 'reflected' }
    when 'nuclei' then { matcher_name: 'word', extracted_results: ['root:x:0:0'], curl_command: 'curl ...' }
    when 'sqlmap' then { payload: "1 AND SLEEP(5)", dbms: %w[MySQL PostgreSQL MSSQL][variant % 3] }
    when 'ffuf' then { status_code: [200, 403, 301, 200][variant % 4], content_length: 1024 + variant }
    when 'nikto' then { message: 'Server reveals information', method: 'GET' }
    when 'testssl' then { protocol: 'TLSv1.0', cipher: 'ECDHE-RSA-AES128-SHA' }
    when 'retirejs' then { identifiers_summary: 'Known XSS in this version' }
    when 'trufflehog' then { detector_name: %w[AWS GitHub Stripe SlackWebhook][variant % 4], redacted: 'AKIA****************' }
    when 'amass' then { source: 'crtsh' }
    else {}
    end
  end

  def duplicate_of(finding, idx)
    dup = JSON.parse(JSON.generate(finding), symbolize_names: true)
    dup[:id] = uuid("realistic:#{idx}")
    dup[:detected_at] = iso(idx)
    dup[:ext] = { synthetic: { generated: true, series: 'realistic', index: idx, duplicate_of: finding[:id] } }
    dup # same identity tuple ⇒ same fingerprint ⇒ a dedup target
  end

  # --- perturbed series ---------------------------------------------------

  MUTATIONS = %i[
    contradictory_severity impossible_scores malformed_identifier wrong_locator_kind
    garbage_evidence missing_required unicode_overflow deep_ext nonsensical_combo null_storm
  ].freeze

  def build_perturbed(rng, realistic)
    Array.new(PERTURBED_COUNT) do |i|
      mutation = MUTATIONS[i % MUTATIONS.length]
      seed_finding = JSON.parse(JSON.generate(realistic[i % realistic.length]), symbolize_names: true)
      perturb(seed_finding, mutation, i, rng)
    end
  end

  def perturb(f, mutation, idx, rng)
    f[:id] = uuid("perturbed:#{idx}")
    f[:detected_at] = iso(idx)
    case mutation
    when :contradictory_severity then f[:finding_type] = 'asset'; f[:severity] = 'critical'
    when :impossible_scores then f[:scores] = { cvss_score: 13.7, epss_score: 1.9, cvss_vector: 'CVSS:9.9/???' }
    when :malformed_identifier then f[:identifiers] = [{ type: 'cve', value: 'CVE-99999-NONSENSE' }, { type: 'cwe', value: 'CWE-abc' }]
    when :wrong_locator_kind then f[:location] = { kind: 'network', host: nil, port: 'eighty', protocol: 42 }
    when :garbage_evidence then f[:evidence] = { '' => nil, " " => "� garbage ‮" }
    when :missing_required then f.delete(:title); f.delete(:location)
    when :unicode_overflow then f[:title] = ('🛰️' * 200) + ("A" * 5000)
    when :deep_ext then f[:ext] = deep_nest(40)
    when :nonsensical_combo then f[:probe] = 'sqlmap'; f[:location] = { kind: 'package', name: 12_345, version: %w[a b] }
    when :null_storm then %i[probe source_tool finding_type title severity location identifiers].each { |k| f[k] = nil }
    end
    f[:ext] = (f[:ext].is_a?(Hash) ? f[:ext] : {}).merge(
      synthetic: { generated: true, series: 'perturbed', index: idx, perturbation: mutation.to_s, label: 'escalate' }
    )
    f.compact
  end

  def deep_nest(depth)
    depth.zero? ? { leaf: true } : { nested: deep_nest(depth - 1) }
  end

  # --- envelope + manifest ------------------------------------------------

  def envelope(findings, series:)
    {
      schema_version: CONTRACT_VERSION,
      scan_id: SCAN_ID,
      metadata: {
        synthetic: true, series: series,
        substrate: { platform: 'gce', machine_type: 'e2-standard-2', provisioning: 'on-demand' }, # #970 (optional, never an enrichment prerequisite)
        vm_timing: { created_at: iso(0), deleted_at: iso(600), wall_clock_seconds: 600 }          # #954
      },
      summary: { total_findings: findings.length },
      tool_chain: {
        executed: PROBES.map { |p| { tool: p[:tool], status: 'completed', exit_code: 0,
                                     findings_count: findings.count { |f| f[:source_tool] == p[:tool] } } } +
          [{ tool: 'sqlmap', status: 'failed', exit_code: nil, findings_count: nil }] # failed tool stays visible (#971)
      },
      findings: findings
    }
  end

  def manifest(realistic, perturbed)
    {
      name: 'penetrator synthetic finding corpus',
      synthetic: true,
      not_ground_truth: 'Bootstrap material only — replace with a real corpus as it accrues.',
      contract_version: CONTRACT_VERSION,
      contract_doc: 'docs/probe_contract.md',
      seed: SEED,
      counts: { realistic: realistic.length, perturbed: perturbed.length },
      series: {
        realistic: 'Well-formed findings across all nine reference probes; ~half with a CVE.',
        perturbed: 'Out-of-distribution findings labelled ext.synthetic.perturbation + label=escalate — the Knowledge-Loop boundary class, not garbage.'
      },
      files: %w[realistic.json perturbed.json]
    }
  end

  # --- deterministic helpers ----------------------------------------------

  def uuid(salt)
    h = Digest::SHA256.hexdigest("#{SEED}:#{salt}")
    [h[0, 8], h[8, 4], h[12, 4], h[16, 4], h[20, 12]].join('-')
  end

  def iso(offset_seconds)
    (BASE_TIME + offset_seconds).strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  def fingerprint(f)
    loc = f[:location] || {}
    tuple = [f[:title]&.downcase&.strip,
             "#{loc[:host] || host_of(loc[:url])}#{loc[:path] || path_of(loc[:url])}",
             loc[:parameter]&.to_s&.downcase,
             f[:identifiers]&.find { |i| i[:type] == 'cwe' }&.dig(:value)].compact.join(':')
    "sha256:#{Digest::SHA256.hexdigest(tuple)}"
  end

  def host_of(url)
    url ? url.to_s.split('/')[2] : nil
  end

  def path_of(url)
    url ? "/#{url.to_s.split('/')[3..]&.join('/')}" : nil
  end

  def pretty(obj)
    "#{JSON.pretty_generate(obj)}\n"
  end
end
