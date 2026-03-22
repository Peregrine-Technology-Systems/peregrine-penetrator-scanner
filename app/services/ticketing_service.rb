class TicketingService
  SEVERITY_ORDER = %w[critical high medium low].freeze

  def initialize(scan)
    @scan = scan
    @target = scan.target
  end

  def create_tickets
    return 0 unless @target.ticketing_enabled?

    tracker = build_tracker
    return 0 unless tracker

    findings = qualifying_findings
    return 0 if findings.empty?

    already_ticketed = load_existing_tickets(findings)
    created = 0

    findings.each do |finding|
      next if already_ticketed[finding.fingerprint]

      result = tracker.create_issue(finding, @target.name)
      next unless result

      stamp_finding(finding, result)
      created += 1
      sleep 1
    end

    log_summary(created, findings.size)
    created
  rescue StandardError => e
    Penetrator.logger.error("[TicketingService] Failed: #{e.message}")
    0
  end

  private

  def build_tracker
    case @target.ticket_tracker
    when 'github'
      build_github_tracker
    else
      Penetrator.logger.warn("[TicketingService] Unsupported tracker: #{@target.ticket_tracker}")
      nil
    end
  end

  def build_github_tracker
    config = @target.ticket_config
    token = ENV.fetch(config['token_env'], nil)

    unless token
      Penetrator.logger.error("[TicketingService] Token env '#{config['token_env']}' not set")
      return nil
    end

    Trackers::GithubTracker.new(owner: config['owner'], repo: config['repo'], token:)
  end

  def qualifying_findings
    min = @target.ticket_config&.dig('min_severity') || 'low'
    severities = SEVERITY_ORDER.first(SEVERITY_ORDER.index(min).to_i + 1)

    @scan.findings.non_duplicate.where(severity: severities)
  end

  def load_existing_tickets(findings)
    return {} unless BigQueryLogger.enabled?

    fingerprints = findings.map(&:fingerprint)
    site = @target.url_list.first
    BigqueryDedup.new.existing_tickets(site, fingerprints)
  end

  def stamp_finding(finding, result)
    evidence = finding.evidence || {}
    evidence = JSON.parse(evidence) if evidence.is_a?(String)

    evidence['ticket_system'] = @target.ticket_tracker
    evidence['ticket_ref'] = result[:ticket_ref]
    evidence['ticket_url'] = result[:ticket_url]
    evidence['ticket_pushed_at'] = Time.current.iso8601

    finding.update(evidence: evidence)
  end

  def log_summary(created, total)
    Penetrator.logger.info("[TicketingService] Created #{created} tickets for #{total} qualifying findings")
  end
end
