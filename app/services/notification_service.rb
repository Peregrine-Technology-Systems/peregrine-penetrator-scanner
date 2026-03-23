class NotificationService
  def initialize(scan)
    @scan = scan
    @slack_notifier = Notifiers::SlackNotifier.new(scan)
  end

  def notify
    @slack_notifier.send_notification if Notifiers::SlackNotifier.configured?
  rescue StandardError => e
    Penetrator.logger.error("[NotificationService] Notification failed: #{e.message}")
  end
end
