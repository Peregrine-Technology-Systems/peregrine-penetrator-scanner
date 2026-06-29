# frozen_string_literal: true

require 'json'
require 'securerandom'

class AuditLogger
  ACTIONS = %w[
    scan_started scan_completed scan_failed
    json_exported
  ].freeze

  def initialize
    @logger = Penetrator.logger
  end

  def log(action:, scan_id:, **fields)
    entry = {
      event: 'audit',
      event_id: SecureRandom.uuid,
      timestamp: Time.now.utc.iso8601,
      action:,
      scan_id:,
      actor: actor_identity,
      schema_version: defined?(ScanResultsExporter) ? ScanResultsExporter::SCHEMA_VERSION : nil
    }.merge(fields).compact

    @logger.info(entry.to_json)
    entry
  end

  def scan_started(scan)
    log(
      action: 'scan_started',
      scan_id: scan.id,
      target_name: scan.target.name,
      profile: scan.profile
    )
  end

  def scan_completed(scan, gcs_path: nil)
    log(
      action: 'scan_completed',
      scan_id: scan.id,
      target_name: scan.target.name,
      profile: scan.profile,
      finding_count: scan.findings_dataset.non_duplicate.count,
      duration_seconds: scan.duration&.to_i,
      status: scan.status,
      gcs_output_path: gcs_path
    )
  end

  def scan_failed(scan, error:)
    log(
      action: 'scan_failed',
      scan_id: scan.id,
      target_name: scan.target.name,
      profile: scan.profile,
      duration_seconds: scan.duration&.to_i,
      status: 'failed',
      error: error.to_s.truncate(500)
    )
  end

  def json_exported(scan, gcs_path:)
    log(
      action: 'json_exported',
      scan_id: scan.id,
      gcs_output_path: gcs_path,
      finding_count: scan.findings_dataset.non_duplicate.count
    )
  end

  private

  def actor_identity
    {
      vm_name: ENV['VM_NAME'] || ENV['HOSTNAME'] || Socket.gethostname,
      service_account: ENV.fetch('GOOGLE_SERVICE_ACCOUNT', nil),
      scan_mode: ENV.fetch('SCAN_MODE', 'dev'),
      # Boot image of the scan VM, for version traceability (#951). bin/scan
      # stamps BOOT_IMAGE from the GCE metadata server at startup; absent off-GCE
      # (compact drops it), so non-VM runs are unaffected.
      boot_image: ENV.fetch('BOOT_IMAGE', nil)
    }.compact
  end
end
