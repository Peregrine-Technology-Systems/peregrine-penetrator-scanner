module Notifiers
  class SlackNotifier
    def initialize(scan)
      @scan = scan
    end

    def send_notification
      url = ENV.fetch('SLACK_WEBHOOK_URL', nil)
      payload = build_payload

      response = Faraday.post(url) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      Rails.logger.info("[NotificationService] Webhook sent: #{response.status}")
    end

    def self.configured?
      ENV['SLACK_WEBHOOK_URL'].present?
    end

    private

    def build_payload
      summary = @scan.summary || {}
      severity = summary['by_severity'] || {}

      {
        text: "Scan Complete: #{@scan.target.name}",
        blocks: [
          {
            type: 'header',
            text: { type: 'plain_text', text: "Scan Complete: #{@scan.target.name}" }
          },
          {
            type: 'section',
            fields: [
              { type: 'mrkdwn', text: "*Profile:* #{@scan.profile}" },
              { type: 'mrkdwn', text: "*Total Findings:* #{summary['total_findings'] || 0}" },
              { type: 'mrkdwn', text: "*Critical:* #{severity['critical'] || 0}" },
              { type: 'mrkdwn', text: "*High:* #{severity['high'] || 0}" },
              { type: 'mrkdwn', text: "*Medium:* #{severity['medium'] || 0}" },
              { type: 'mrkdwn', text: "*Low:* #{severity['low'] || 0}" }
            ]
          }
        ]
      }
    end
  end
end
