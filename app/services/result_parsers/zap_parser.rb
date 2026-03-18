module ResultParsers
  class ZapParser
    SEVERITY_MAP = { '0' => 'info', '1' => 'low', '2' => 'medium', '3' => 'high' }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      alerts = data['site']&.flat_map { |s| s['alerts'] || [] } || []

      alerts.map do |alert|
        instances = alert['instances'] || []
        instances.map do |instance|
          {
            source_tool: 'zap',
            severity: SEVERITY_MAP[alert['riskcode'].to_s] || 'info',
            title: alert['name'] || alert['alert'],
            url: instance['uri'],
            parameter: instance['param'],
            cwe_id: alert['cweid'].present? ? "CWE-#{alert['cweid']}" : nil,
            evidence: {
              description: alert['desc'],
              solution: alert['solution'],
              reference: alert['reference'],
              evidence: instance['evidence'],
              method: instance['method']
            }.compact
          }
        end
      end.flatten
    rescue JSON::ParserError, Errno::ENOENT => e
      Rails.logger.error("[ZapParser] Parse error: #{e.message}")
      []
    end
  end
end
