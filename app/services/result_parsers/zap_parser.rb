module ResultParsers
  class ZapParser
    SEVERITY_MAP = { '0' => 'info', '1' => 'low', '2' => 'medium', '3' => 'high' }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      alerts = data['site']&.flat_map { |s| s['alerts'] || [] } || []
      alerts.flat_map { |alert| (alert['instances'] || []).map { |instance| build(alert, instance) } }
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[ZapParser] Parse error: #{e.message}")
      []
    end

    private

    def build(alert, instance)
      Contract.finding(
        source_tool: 'zap', probe: 'web-dast', finding_type: 'vulnerability',
        tool_check_id: alert['pluginid'],
        severity: SEVERITY_MAP[alert['riskcode'].to_s] || 'info',
        severity_source: alert['riskdesc'],
        title: alert['name'] || alert['alert'],
        description: alert['desc'],
        location: Contract.web(url: instance['uri'], method: instance['method'], parameter: instance['param']),
        identifiers: [Contract.identifier('cwe', cwe(alert))],
        evidence: {
          'solution' => alert['solution'], 'reference' => alert['reference'],
          'evidence' => instance['evidence']
        }
      )
    end

    def cwe(alert)
      code = alert['cweid'].to_s
      code.empty? || %w[-1 0].include?(code) ? nil : "CWE-#{code}"
    end
  end
end
