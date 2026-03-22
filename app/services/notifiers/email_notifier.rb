module Notifiers
  class EmailNotifier
    def initialize(scan)
      @scan = scan
    end

    def send_notification
      summary = @scan.summary || {}
      target_name = @scan.target.name

      mail = build_mail(target_name, summary)
      attach_pdf_report(mail)

      mail.delivery_method :smtp, smtp_settings
      mail.deliver
      Penetrator.logger.info('[NotificationService] Email sent')
    end

    def self.configured?
      ENV['SMTP_HOST'].present?
    end

    def build_email_html(target_name, summary)
      severity = summary['by_severity'] || {}
      <<~HTML
        <h2>Penetration Test Scan Complete</h2>
        <p><strong>Target:</strong> #{target_name}</p>
        <p><strong>Profile:</strong> #{@scan.profile}</p>
        <p><strong>Total Findings:</strong> #{summary['total_findings'] || 0}</p>
        <table border="1" cellpadding="5">
          <tr><th>Severity</th><th>Count</th></tr>
          <tr><td style="color:red">Critical</td><td>#{severity['critical'] || 0}</td></tr>
          <tr><td style="color:orange">High</td><td>#{severity['high'] || 0}</td></tr>
          <tr><td style="color:#cc0">Medium</td><td>#{severity['medium'] || 0}</td></tr>
          <tr><td style="color:blue">Low</td><td>#{severity['low'] || 0}</td></tr>
          <tr><td style="color:gray">Info</td><td>#{severity['info'] || 0}</td></tr>
        </table>
      HTML
    end

    def smtp_settings
      {
        address: ENV.fetch('SMTP_HOST', 'mail.authsmtp.com'),
        port: ENV.fetch('SMTP_PORT', '2525').to_i,
        user_name: ENV.fetch('SMTP_USERNAME', nil),
        password: ENV.fetch('SMTP_PASSWORD', nil),
        authentication: :login,
        enable_starttls_auto: true,
        open_timeout: 10,
        read_timeout: 10
      }
    end

    private

    def build_mail(target_name, summary)
      html_body = build_email_html(target_name, summary)

      Mail.new do
        from    ENV.fetch('SMTP_FROM', 'pentest@peregrine-tech.com')
        to      ENV.fetch('NOTIFICATION_EMAIL', 'security@peregrine-tech.com')
        subject "Scan Complete: #{target_name} - #{summary['total_findings'] || 0} findings"

        html_part do
          content_type 'text/html; charset=UTF-8'
          body html_body
        end
      end
    end

    def attach_pdf_report(mail)
      pdf_report = @scan.reports.find_by(format: 'pdf', status: 'completed')
      return unless pdf_report&.gcs_path

      local_path = Penetrator.root.join('storage', 'reports', pdf_report.gcs_path)
      mail.add_file(filename: 'scan_report.pdf', content: File.read(local_path)) if File.exist?(local_path)
    end
  end
end
