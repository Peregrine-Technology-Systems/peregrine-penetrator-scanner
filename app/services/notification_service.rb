class NotificationService
  def initialize(scan)
    @scan = scan
    @slack_notifier = Notifiers::SlackNotifier.new(scan)
    @email_notifier = Notifiers::EmailNotifier.new(scan)
  end

  def notify
    @slack_notifier.send_notification if Notifiers::SlackNotifier.configured?
    @email_notifier.send_notification if Notifiers::EmailNotifier.configured?
  rescue StandardError => e
    Penetrator.logger.error("[NotificationService] Notification failed: #{e.message}")
  end

  private

  def send_email
    @email_notifier.send_notification
  end

  def build_email_html(target_name, summary)
    @email_notifier.build_email_html(target_name, summary)
  end

  def smtp_settings
    @email_notifier.smtp_settings
  end
end
