namespace :scan do
  desc 'Run a penetration test scan'
  task run: :environment do
    profile = ENV.fetch('SCAN_PROFILE', 'standard')
    target_name = ENV.fetch('TARGET_NAME', 'Default Target')
    target_urls = JSON.parse(ENV.fetch('TARGET_URLS', '["http://localhost:8080"]'))

    puts '=== Web Application Penetration Test ==='
    puts "Profile: #{profile}"
    puts "Target: #{target_name}"
    puts "URLs: #{target_urls.join(', ')}"
    puts "Started: #{Time.current}"
    puts '=' * 40

    # Find or create target
    target = Target.find_or_create_by!(name: target_name) do |t|
      t.urls = target_urls
    end

    # Create scan
    scan = target.scans.create!(profile:)
    puts "Scan ID: #{scan.id}"

    # Initialize cost tracker
    cost_logger = ScanCostLogger.new(scan)

    # Execute scan
    orchestrator = ScanOrchestrator.new(scan)
    orchestrator.execute

    # Enrich with CVE intelligence
    if scan.findings.where.not(cve_id: [nil, '']).any?
      puts "\n--- CVE Intelligence Enrichment ---"
      CveIntelligenceService.new.enrich_scan(scan)
    end

    # AI Analysis (if API key configured)
    if ENV['ANTHROPIC_API_KEY'].present?
      puts "\n--- AI Analysis ---"
      AiAnalyzer.new.analyze_scan(scan)
    end

    # Create remediation tickets
    if scan.target.ticketing_enabled?
      puts "\n--- Remediation Tickets ---"
      created = TicketingService.new(scan).create_tickets
      puts "  Created #{created} tickets"
    end

    # Generate reports
    puts "\n--- Report Generation ---"
    generator = ReportGenerator.new(scan)
    reports = generator.generate_all
    reports.each do |report|
      puts "  #{report.format.upcase}: #{report.gcs_path || 'local'} (#{report.status})"
    end

    # Log findings to BigQuery
    if BigQueryLogger.enabled?
      puts "\n--- Finding History ---"
      logged = BigQueryLogger.new.log_findings(scan)
      puts "  Logged #{logged} findings to BigQuery (#{ENV.fetch('SCAN_MODE', 'dev')})"
    end

    # Log scan costs to BigQuery
    if BigQueryLogger.enabled?
      puts "\n--- Cost Tracking ---"
      if cost_logger.log_to_bigquery
        data = cost_logger.cost_data
        puts "  VM: #{data[:vm_type]}, Runtime: #{data[:vm_runtime_seconds]}s, " \
             "Est. cost: $#{format('%.4f', data[:estimated_cost_usd])}"
      else
        puts '  Cost logging skipped or failed'
      end
    end

    # Send notifications
    puts "\n--- Notifications ---"
    NotificationService.new(scan).notify

    # Summary
    scan.reload
    summary = scan.summary || {}
    puts "\n=== Scan Complete ==="
    puts "Duration: #{scan.duration&.to_i}s"
    puts "Total Findings: #{summary['total_findings']}"
    (summary['by_severity'] || {}).each do |sev, count|
      puts "  #{sev}: #{count}"
    end
    puts '=' * 40
  end

  desc 'List available scan profiles'
  task profiles: :environment do
    ScanProfile.available.each do |name|
      profile = ScanProfile.load(name)
      puts "#{name}: #{profile.description} (~#{profile.estimated_duration_minutes} min)"
      profile.phases.each do |phase|
        tools = phase.tools.map(&:tool).join(', ')
        parallel = phase.parallel ? ' [parallel]' : ''
        puts "  Phase #{phase.name}: #{tools}#{parallel}"
      end
      puts
    end
  end

  desc 'Validate scan profile YAML files'
  task validate_profiles: :environment do
    errors = []
    ScanProfile.available.each do |name|
      profile = ScanProfile.load(name)
      puts "#{name}: valid (#{profile.phases.length} phases)"
    rescue StandardError => e
      errors << "#{name}: #{e.message}"
      puts errors.last
    end

    exit 1 if errors.any?
  end

  desc 'Generate Nuclei templates for uncovered CVEs'
  task generate_templates: :environment do
    cve_ids = ENV.fetch('CVE_IDS', '').split(',').map(&:strip)

    if cve_ids.empty?
      puts 'Usage: rake scan:generate_templates CVE_IDS=CVE-2024-1234,CVE-2024-5678'
      exit 1
    end

    generator = NucleiTemplateGenerator.new
    results = generator.generate_batch(cve_ids)

    results.each do |r|
      status = r[:success] ? 'generated' : 'failed'
      puts "#{status} #{r[:cve_id]}: #{r[:template_path] || 'failed'}"
    end
  end
end
