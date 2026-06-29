module ResultParsers
  # Normalizes retire.js `--outputformat json` output into probe-contract findings.
  # retire.js emits a flat object: {data:[{file, results:[{component, version,
  # vulnerabilities:[{severity, identifiers:{summary, CVE?:[]}, cwe?:[]}]}]}]}.
  # One finding per vulnerability (not per file/component). See #51.
  class RetirejsParser
    def initialize(output_file, target_url)
      @output_file = output_file
      @target_url  = target_url
    end

    def parse
      data = JSON.parse(File.read(@output_file)).fetch('data', [])
      data.flat_map { |item| parse_item(item) }
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[RetirejsParser] Parse error: #{e.message}")
      []
    end

    private

    def parse_item(item)
      item.fetch('results', []).flat_map do |result|
        result.fetch('vulnerabilities', []).map { |vuln| build_finding(result, vuln) }
      end
    end

    def build_finding(result, vuln)
      ids = vuln.fetch('identifiers', {})
      Contract.finding(
        source_tool: 'retirejs', probe: 'sca', finding_type: 'outdated-component',
        severity: vuln['severity'],
        title: ids['summary'].to_s,
        location: Contract.package(name: result['component'], version: result['version'], ecosystem: 'npm'),
        component: { 'name' => result['component'], 'version' => result['version'], 'ecosystem' => 'npm' },
        identifiers: identifiers(ids, vuln),
        evidence: { 'identifiers_summary' => ids['summary'].to_s, 'affected_url' => @target_url }
      )
    end

    # Preserve ALL CVEs/CWEs/GHSAs the advisory cites — the flat model kept only
    # the first of each; identifiers[] is lossless (#971).
    def identifiers(ids, vuln)
      Array(ids['CVE']).map { |c| Contract.identifier('cve', c) } +
        Array(vuln['cwe']).map { |c| Contract.identifier('cwe', c) } +
        Array(ids['GHSA']).map { |g| Contract.identifier('ghsa', g) }
    end
  end
end
