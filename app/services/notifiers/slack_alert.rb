module Notifiers
  class SlackAlert
    SEVERITY_EMOJI = { warning: ':warning:', error: ':x:', critical: ':rotating_light:' }.freeze

    # Track sent alerts to debounce (max 1 per tool per scan)
    @sent_alerts = {}

    class << self
      def send_alert(scan:, tool:, message:, severity: :warning, action: nil)
        return unless configured?
        return if debounce(scan.id, tool)

        payload = build_payload(scan, tool, severity, message, action)
        post(payload)
      rescue StandardError => e
        Penetrator.logger.error("[SlackAlert] Failed to send alert: #{e.message}")
      end

      def reset_debounce!
        @sent_alerts = {}
      end

      private

      def configured?
        ENV.fetch('SLACK_WEBHOOK_URL', nil).present?
      end

      def debounce(scan_id, tool)
        key = "#{scan_id}:#{tool}"
        return true if @sent_alerts[key]

        @sent_alerts[key] = Time.current
        false
      end

      def build_payload(scan, tool, severity, message, action)
        emoji = SEVERITY_EMOJI[severity] || ':warning:'
        target_name = begin
          scan.target.name
        rescue StandardError
          'unknown'
        end

        blocks = [
          {
            type: 'header',
            text: { type: 'plain_text', text: "#{emoji} Scan Alert: #{severity.to_s.capitalize}", emoji: true }
          },
          {
            type: 'section',
            text: {
              type: 'mrkdwn',
              text: [
                "*Target:* #{target_name}",
                "*Tool:* #{tool}",
                "*Error:* #{message}",
                "*Time:* #{Time.current.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}",
                "*Scan ID:* `#{scan.id[0..7]}`",
                action ? "*Action:* #{action}" : nil
              ].compact.join("\n")
            }
          }
        ]

        { text: "#{emoji} Scan Alert: #{tool} — #{message}", blocks: }
      end

      def post(payload)
        url = ENV.fetch('SLACK_WEBHOOK_URL', nil)
        response = Faraday.post(url) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.body = payload.to_json
        end
        Penetrator.logger.info("[SlackAlert] Alert sent: #{response.status}")
      end
    end
  end
end
