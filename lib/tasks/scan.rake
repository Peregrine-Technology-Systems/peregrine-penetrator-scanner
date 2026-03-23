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
    target = Target.find_or_create(name: target_name) { |t| t.urls = target_urls }

    # Create scan
    scan = Scan.create(target_id: target.id, profile:)
    puts "Scan ID: #{scan.id}"

    # Initialize cost tracker and audit logger
    cost_logger = ScanCostLogger.new(scan)
    audit = AuditLogger.new
    audit.scan_started(scan)

    # Execute scan
    orchestrator = ScanOrchestrator.new(scan)
    orchestrator.execute

    # Enrich with CVE intelligence
    if scan.findings_dataset.exclude(cve_id: nil).exclude(cve_id: '').count.positive?
      puts "\n--- CVE Intelligence Enrichment ---"
      CveIntelligenceService.new.enrich_scan(scan)
    end

    # Export versioned JSON to GCS (canonical scan output)
    puts "\n--- Scan Results Export ---"
    gcs_scan_results_path = ScanResultsExporter.new(scan).export
    puts "  Exported v#{ScanResultsExporter::SCHEMA_VERSION} to #{gcs_scan_results_path}"
    audit.json_exported(scan, gcs_path: gcs_scan_results_path)

    # Load findings to BigQuery FROM the versioned JSON
    if BigQueryLogger.enabled?
      puts "\n--- Finding History (JSON-first) ---"
      scan_results = ScanResultsExporter.new(scan).build_envelope
      logged = BigQueryLogger.new.log_from_json(scan_results)
      puts "  Logged #{logged} findings to BigQuery (#{ENV.fetch('SCAN_MODE', 'dev')})"
      audit.bq_loaded(scan, rows_logged: logged)
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

    # Callback to backend API (now includes GCS scan results path)
    if ScanCallbackService.enabled?
      puts "\n--- Backend Callback ---"
      if ScanCallbackService.new(scan, cost_logger, gcs_scan_results_path:).notify
        puts "  Callback sent to #{ENV.fetch('CALLBACK_URL', 'unknown')}"
      else
        puts '  Callback failed (scan still succeeded)'
      end
    end

    # Audit: scan completed
    audit.scan_completed(scan, gcs_path: gcs_scan_results_path)

    # Send notifications
    puts "\n--- Notifications ---"
    NotificationService.new(scan).notify

    # Summary
    scan.refresh
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
end
