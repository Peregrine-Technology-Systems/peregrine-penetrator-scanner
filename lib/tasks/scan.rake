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

    audit = AuditLogger.new
    audit.scan_started(scan)

    # Execute scan
    orchestrator = ScanOrchestrator.new(scan)
    orchestrator.execute

    # Export versioned JSON to GCS (canonical scan output)
    puts "\n--- Scan Results Export ---"
    exporter = ScanResultsExporter.new(scan)
    gcs_scan_results_path = exporter.export
    puts "  Exported v#{ScanResultsExporter::SCHEMA_VERSION} to #{gcs_scan_results_path}"
    audit.json_exported(scan, gcs_path: gcs_scan_results_path)

    # Write completion status to GCS — orchestrator polls this to detect scan completion
    scan_uuid = ENV.fetch('SCAN_UUID', scan.id)
    StorageService.new.upload_json("control/#{scan_uuid}/status.json", {
                                     phase: 'completed',
                                     timestamp: Time.current.iso8601,
                                     results_path: gcs_scan_results_path
                                   })
    puts "\n--- Completion Status ---"
    puts "  Written control/#{scan_uuid}/status.json (results_path: #{gcs_scan_results_path})"

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
