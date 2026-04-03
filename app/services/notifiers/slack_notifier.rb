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

      Penetrator.logger.info("[NotificationService] Webhook sent: #{response.status}")
    end

    def self.configured?
      ENV['SLACK_WEBHOOK_URL'].present?
    end

    def self.send_started(scan)
      return unless configured?

      target_name = begin
        scan.target.name
      rescue StandardError
        'unknown'
      end

      payload = {
        text: ":rocket: Scan started: #{target_name} (#{scan.profile})",
        blocks: [
          {
            type: 'section',
            text: {
              type: 'mrkdwn',
              text: [
                ":rocket: *Scan Started*",
                "*Target:* #{target_name}",
                "*Profile:* #{scan.profile}",
                "*Scan ID:* `#{scan.id[0..7]}`"
              ].join("\n")
            }
          }
        ]
      }

      url = ENV.fetch('SLACK_WEBHOOK_URL', nil)
      Faraday.post(url) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end
    rescue StandardError => e
      Penetrator.logger.error("[SlackNotifier] Failed to send start notification: #{e.message}")
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
