# frozen_string_literal: true

# Executes one scan job end-to-end: target/scan creation, orchestration, results
# export, completion signaling. Extracted from bin/scan (scanner#1171) so a
# single worker process can run this once per pull inside Bus::WorkerLoop's poll
# loop, not just once at boot. The smoke-test path returns a Result instead of
# calling `exit` directly — a poll-loop worker must survive a smoke-profile job,
# not die after it; the off-bus single-shot caller (bin/scan) is the one that
# decides whether to translate a failed Result into a process exit code.
class ScanJobRunner
  Result = Struct.new(:scan, :passed, keyword_init: true)

  def initialize(profile:, target_name:, target_urls:)
    @profile = profile
    @target_name = target_name
    @target_urls = target_urls
  end

  def call
    puts '=== Web Application Penetration Test ==='
    puts "Profile: #{@profile}"
    puts "Target: #{@target_name}"
    puts "URLs: #{@target_urls.join(', ')}"
    puts "Started: #{Time.current}"
    puts '=' * 40

    target = Target.find_or_create(name: @target_name) { |t| t.urls = @target_urls }
    scan = Scan.create(target_id: target.id, profile: @profile)
    puts "Scan ID: #{scan.id}"

    audit = AuditLogger.new
    audit.scan_started(scan)

    ScanOrchestrator.new(scan).execute

    return smoke_result(scan, audit) if %w[smoke smoke-test].include?(@profile)

    full_result(scan, audit)
  end

  private

  def smoke_result(scan, audit)
    puts "\n--- Smoke Test Export ---"
    gcs_path = ScanResultsExporter.new(scan).export
    puts "  Exported to #{gcs_path}"
    audit.scan_completed(scan, gcs_path: gcs_path)

    scan.refresh
    passed = scan.status == 'completed'
    puts "\n=== Smoke Test #{passed ? 'PASSED' : 'FAILED'} ==="
    Result.new(scan:, passed:)
  end

  def full_result(scan, audit)
    # Export versioned JSON to GCS
    puts "\n--- Scan Results Export ---"
    exporter = ScanResultsExporter.new(scan)
    gcs_scan_results_path = exporter.export
    puts "  Exported v#{ScanResultsExporter::SCHEMA_VERSION} to #{gcs_scan_results_path}"
    audit.json_exported(scan, gcs_path: gcs_scan_results_path)

    # Write completion status to GCS — the consumer polls this to detect completion
    # (#906: GCS-only completion; ScanCallbackService removed). Enriched with the bus
    # envelope identity (#1009) so the durable fallback carries transaction_id/trace id.
    identity = ScanIdentity.from_env(scan_id: scan.id)
    scan_uuid = identity.scan_uuid
    StorageService.new.upload_json("control/#{scan_uuid}/status.json", {
      phase: 'completed',
      timestamp: Time.now.utc.iso8601,
      results_path: gcs_scan_results_path,
      boot_image: ENV.fetch('BOOT_IMAGE', InstanceMetadata::UNKNOWN)
    }.merge(identity.to_h.except(:scan_uuid)))
    puts "\n--- Completion Status ---"
    puts "  Written control/#{scan_uuid}/status.json (results_path: #{gcs_scan_results_path})"

    # Publish the bus completion event (#1009): a claim-check pointer to the report
    # blob, never the bytes. Inert until the bus substrate is wired at deploy; the GCS
    # status.json above stays the orchestrator's durable fallback.
    ScanCompletionPublisher.new(scan, exporter:, identity:).emit
    puts '  Published scan completion to the bus'

    audit.scan_completed(scan, gcs_path: gcs_scan_results_path)

    scan.refresh
    summary = scan.summary || {}
    puts "\n=== Scan Complete ==="
    puts "Duration: #{scan.duration&.to_i}s"
    puts "Total Findings: #{summary['total_findings']}"
    (summary['by_severity'] || {}).each do |sev, count|
      puts "  #{sev}: #{count}"
    end
    puts '=' * 40

    Result.new(scan:, passed: true)
  end
end
