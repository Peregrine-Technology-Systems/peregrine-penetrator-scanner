require "pulumi"
require "pulumi-gcp"

# Configuration
config = Pulumi::Config.new("pentest-platform")
gcp_config = Pulumi::Config.new("gcp")
project = gcp_config.require("project")
region = gcp_config.get("region") || "us-central1"
schedule = config.get("schedule") || "0 2 * * *"
scan_profile = config.get("scan_profile") || "standard"

# Artifact Registry
registry = Gcp::ArtifactRegistry::Repository.new("pentest-registry",
  repository_id: "pentest",
  location: region,
  format: "DOCKER",
  description: "Penetration testing platform Docker images"
)

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

# Cloud Run Job
image_url = "#{region}-docker.pkg.dev/#{project}/pentest/scanner:latest"

scanner_job = Gcp::CloudRunV2::Job.new("pentest-scanner",
  name: "pentest-scanner",
  location: region,
  template: {
    template: {
      containers: [{
        image: image_url,
        resources: {
          limits: {
            cpu: "4",
            memory: "16Gi"
          }
        },
        envs: [
          { name: "SCAN_PROFILE", value: scan_profile },
          { name: "RAILS_ENV", value: "production" },
          { name: "GCS_BUCKET", value_source: { secret_key_ref: nil } },
          { name: "ANTHROPIC_API_KEY", value_source: {
            secret_key_ref: { secret: "pentest-anthropic-api-key", version: "latest" }
          }},
          { name: "NVD_API_KEY", value_source: {
            secret_key_ref: { secret: "pentest-nvd-api-key", version: "latest" }
          }},
          { name: "SLACK_WEBHOOK_URL", value_source: {
            secret_key_ref: { secret: "pentest-slack-webhook-url", version: "latest" }
          }},
          { name: "SMTP_HOST", value: "mail.authsmtp.com" },
          { name: "SMTP_PORT", value: "2525" },
          { name: "SMTP_USERNAME", value_source: {
            secret_key_ref: { secret: "pentest-smtp-username", version: "latest" }
          }},
          { name: "SMTP_PASSWORD", value_source: {
            secret_key_ref: { secret: "pentest-smtp-password", version: "latest" }
          }}
        ]
      }],
      timeout: "3600s",
      service_account: scanner_sa.email,
      max_retries: 0
    }
  }
)

# Cloud Scheduler — weekly production scan
scheduler = Gcp::CloudScheduler::Job.new("pentest-schedule",
  name: "pentest-scanner-schedule",
  schedule: schedule,
  time_zone: "UTC",
  region: region,
  http_target: {
    uri: scanner_job.id.apply { |id| "https://#{region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/#{project}/jobs/pentest-scanner:run" },
    http_method: "POST",
    oauth_token: {
      service_account_email: scanner_sa.email
    }
  }
)

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
Pulumi.export("registry_url", registry.id.apply { |_| "#{region}-docker.pkg.dev/#{project}/pentest" })
Pulumi.export("reports_bucket", reports_bucket.name)
Pulumi.export("scanner_job", scanner_job.name)
Pulumi.export("scheduler", scheduler.name)
Pulumi.export("service_account", scanner_sa.email)
Pulumi.export("scavenger_function", scavenger_function.name)
Pulumi.export("scavenger_schedule", scavenger_schedule.name)
