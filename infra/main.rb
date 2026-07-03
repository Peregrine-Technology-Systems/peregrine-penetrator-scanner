require "pulumi"
require "pulumi-gcp"

# Configuration
config = Pulumi::Config.new("pentest-platform")
gcp_config = Pulumi::Config.new("gcp")
project = gcp_config.require("project")
region = gcp_config.get("region") || "us-central1"

# Cloud Storage bucket for reports
reports_bucket = Gcp::Storage::Bucket.new("pentest-reports",
  name: "#{project}-pentest-reports",
  location: region,
  uniform_bucket_level_access: true,
  lifecycle_rules: [{
    action: { type: "Delete" },
    condition: { age: 90 }
  }]
)

# Service account for the scanner
scanner_sa = Gcp::ServiceAccount::Account.new("scanner-sa",
  account_id: "pentest-scanner",
  display_name: "Penetration Test Scanner"
)

# Grant storage access
Gcp::Storage::BucketIAMMember.new("scanner-storage-access",
  bucket: reports_bucket.name,
  role: "roles/storage.objectAdmin",
  member: scanner_sa.email.apply { |e| "serviceAccount:#{e}" }
)

# Grant Secret Manager access
Gcp::Projects::IAMMember.new("scanner-secrets-access",
  project: project,
  role: "roles/secretmanager.secretAccessor",
  member: scanner_sa.email.apply { |e| "serviceAccount:#{e}" }
)

# Secrets
secrets = %w[
  anthropic-api-key
  nvd-api-key
  slack-webhook-url
  smtp-username
  smtp-password
  notification-email
].map do |name|
  Gcp::SecretManager::Secret.new("secret-#{name}",
    secret_id: "pentest-#{name}",
    replication: { auto: {} }
  )
end

# NOTE: production scan SCHEDULING is owned by the orchestrator
# (peregrine-penetrator-orchestrator), not this repo. The legacy Cloud-Run-job
# model (a `pentest-scanner` Cloud Run Job + a `pentest-scanner-schedule` Cloud
# Scheduler job) was removed here — it was never the live mechanism (no Cloud Run
# Job was ever deployed), and the broken out-of-band `weekly-production-scan`
# scheduler that 404'd for weeks has been deleted (scanner #829, per an internal
# infra ruling). Scans are launched via the `trigger-scan-*`
# Cloud Functions (deployed by scripts/deploy-cloud-functions.sh); the
# orchestrator will drive the cron + dispatch.

# Cloud Function — VM scavenger
scavenger_function = Gcp::CloudFunctionsV2::Function.new("vm-scavenger",
  name: "vm-scavenger",
  location: region,
  build_config: {
    runtime: "python312",
    entry_point: "scavenge_vms",
    source: {
      storage_source: {
        bucket: reports_bucket.name,
        object: "cloud-functions/vm-scavenger.zip"
      }
    }
  },
  service_config: {
    max_instance_count: 1,
    timeout_seconds: 300,
    available_memory: "256M",
    service_account_email: scanner_sa.email,
    environment_variables: {
      "GCP_PROJECT" => project,
      "GCP_REGION" => region,
      "MAX_AGE_MINUTES" => "30",
      "HARD_MAX_MINUTES" => "240"
    },
    secret_environment_variables: [{
      key: "SLACK_WEBHOOK_URL",
      project_id: project,
      secret: "pentest-slack-webhook-url",
      version: "latest"
    }]
  }
)

# Grant Cloud Run invoker so scheduler can call the scavenger function
Gcp::CloudRunV2::ServiceIamMember.new("scavenger-invoker",
  name: scavenger_function.service_config.apply { |sc| sc.service },
  location: region,
  role: "roles/run.invoker",
  member: scanner_sa.email.apply { |e| "serviceAccount:#{e}" }
)

# Allow unauthenticated /health checks (function routes health internally)
Gcp::CloudRunV2::ServiceIamMember.new("scavenger-health-public",
  name: scavenger_function.service_config.apply { |sc| sc.service },
  location: region,
  role: "roles/run.invoker",
  member: "allUsers"
)

# Cloud Scheduler — VM scavenger every 10 minutes
scavenger_schedule = Gcp::CloudScheduler::Job.new("vm-scavenger-schedule",
  name: "vm-scavenger-schedule",
  schedule: "*/10 * * * *",
  time_zone: "UTC",
  region: region,
  http_target: {
    uri: scavenger_function.service_config.apply { |sc| sc.uri },
    http_method: "POST",
    oidc_token: {
      service_account_email: scanner_sa.email,
      audience: scavenger_function.service_config.apply { |sc| sc.uri }
    }
  }
)

# Exports
Pulumi.export("reports_bucket", reports_bucket.name)
Pulumi.export("service_account", scanner_sa.email)
Pulumi.export("scavenger_function", scavenger_function.name)
Pulumi.export("scavenger_schedule", scavenger_schedule.name)
