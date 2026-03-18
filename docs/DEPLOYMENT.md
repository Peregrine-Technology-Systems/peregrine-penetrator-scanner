# Deployment Guide

Production deployment instructions for the web application penetration testing platform on Google Cloud Platform.

## Infrastructure Overview

The platform runs as a scheduled batch job on GCP:

```
Cloud Scheduler (cron trigger)
     |
     v
Cloud Run Job (4 vCPU, 16GB RAM, 3600s timeout)
     |
     +-- Runs Docker container with security tools + Rails app
     +-- Reads secrets from Secret Manager
     +-- Writes reports to Cloud Storage
     +-- Sends notifications (Slack webhook, email via authsmtp.com)
```

**Components:**

| Service | Purpose |
|---------|---------|
| **Cloud Run Jobs** | Executes scan container on schedule or on-demand |
| **Cloud Scheduler** | Triggers scans on a cron schedule (default: daily 2am UTC) |
| **Artifact Registry** | Stores Docker images |
| **Cloud Storage** | Stores generated reports (JSON, HTML, PDF) with 90-day lifecycle |
| **Secret Manager** | Stores API keys, SMTP credentials, webhook URLs |

**Infrastructure is managed as code** using Pulumi (Ruby) in the `infra/` directory.

## Prerequisites

- **GCP project** with billing enabled
- **gcloud CLI** installed and authenticated
- **Pulumi CLI** installed (`brew install pulumi` or see [pulumi.com](https://www.pulumi.com/docs/install/))
- **Docker** for building and pushing images
- **GitHub repository** with Actions enabled (for CI/CD)

## Initial GCP Setup

### 1. Create Project and Enable APIs

```bash
# Set your project ID
export GCP_PROJECT="your-project-id"

# Create project (or use existing)
gcloud projects create $GCP_PROJECT

# Set as active project
gcloud config set project $GCP_PROJECT

# Enable required APIs
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com
```

### 2. Create Service Account

```bash
# Create service account for the scanner
gcloud iam service-accounts create pentest-scanner \
  --display-name="Penetration Test Scanner"

# Grant necessary roles
SA_EMAIL="pentest-scanner@${GCP_PROJECT}.iam.gserviceaccount.com"

# Cloud Run invoker (for Cloud Scheduler to trigger jobs)
gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker"

# Secret Manager access
gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"

# Storage object admin (for report uploads)
# Bucket-level binding is created by Pulumi, but project-level works too:
gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"
```

### 3. Set Up Artifact Registry

```bash
# Create Docker repository
gcloud artifacts repositories create pentest \
  --repository-format=docker \
  --location=us-central1 \
  --description="Penetration testing platform Docker images"

# Configure Docker authentication
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### 4. Configure Secrets in Secret Manager

Create each secret that the scanner needs at runtime. Do not store actual values in source control.

```bash
# Create secrets (you will be prompted for values or pipe them in)
echo -n "your-anthropic-key" | gcloud secrets create pentest-anthropic-api-key --data-file=-
echo -n "your-nvd-key" | gcloud secrets create pentest-nvd-api-key --data-file=-
echo -n "https://hooks.slack.com/..." | gcloud secrets create pentest-slack-webhook-url --data-file=-
echo -n "your-smtp-user" | gcloud secrets create pentest-smtp-username --data-file=-
echo -n "your-smtp-pass" | gcloud secrets create pentest-smtp-password --data-file=-
echo -n "security@yourcompany.com" | gcloud secrets create pentest-notification-email --data-file=-
```

Grant the scanner service account access to each secret:

```bash
for SECRET in pentest-anthropic-api-key pentest-nvd-api-key pentest-slack-webhook-url \
              pentest-smtp-username pentest-smtp-password pentest-notification-email; do
  gcloud secrets add-iam-policy-binding $SECRET \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor"
done
```

## Pulumi IaC Deployment

All infrastructure is defined in `infra/main.rb`. Pulumi manages the Artifact Registry, Cloud Storage bucket, service account, Secret Manager secrets, Cloud Run Job, and Cloud Scheduler.

```bash
cd infra

# Install Pulumi Ruby dependencies
bundle install

# Initialize stack (first time only)
pulumi stack init production

# Configure GCP project and region
pulumi config set gcp:project $GCP_PROJECT
pulumi config set gcp:region us-central1

# Optional: customize schedule and scan profile
pulumi config set pentest-platform:schedule "0 2 * * 1"  # Weekly Monday 2am UTC
pulumi config set pentest-platform:scan_profile thorough

# Preview changes
pulumi preview

# Apply infrastructure
pulumi up
```

### Pulumi Outputs

After deployment, Pulumi exports:

| Output | Description |
|--------|-------------|
| `registry_url` | Artifact Registry URL for Docker push |
| `reports_bucket` | GCS bucket name for reports |
| `scanner_job` | Cloud Run Job name |
| `scheduler` | Cloud Scheduler job name |
| `service_account` | Scanner service account email |

```bash
# View outputs
pulumi stack output
```

## Docker Build and Push

```bash
# Build the image
docker build -f docker/Dockerfile -t pentest-platform .

# Tag for Artifact Registry
docker tag pentest-platform \
  us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest/scanner:latest

# Push
docker push us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest/scanner:latest
```

## Cloud Run Job Configuration

The Cloud Run Job is configured with these resource limits (defined in `infra/main.rb`):

| Setting | Value |
|---------|-------|
| **CPU** | 4 vCPU |
| **Memory** | 16 GB |
| **Timeout** | 3600 seconds (1 hour) |
| **Max retries** | 0 (no automatic retry) |
| **Concurrency** | 1 (single execution) |

### Manual Job Execution

```bash
# Trigger a scan manually
gcloud run jobs execute pentest-scanner \
  --region us-central1 \
  --project $GCP_PROJECT

# Trigger with override environment variables
gcloud run jobs execute pentest-scanner \
  --region us-central1 \
  --project $GCP_PROJECT \
  --update-env-vars SCAN_PROFILE=thorough
```

## Cloud Scheduler Configuration

The default schedule is **daily at 2:00 AM UTC** (`0 2 * * *`). This can be customized via Pulumi config:

```bash
# Change to weekly (Monday 2am UTC)
pulumi config set pentest-platform:schedule "0 2 * * 1"
pulumi up

# Or update directly via gcloud
gcloud scheduler jobs update http pentest-scanner-schedule \
  --schedule="0 2 * * 1" \
  --region us-central1
```

### Pause/Resume Scheduling

```bash
# Pause scheduled scans
gcloud scheduler jobs pause pentest-scanner-schedule --region us-central1

# Resume
gcloud scheduler jobs resume pentest-scanner-schedule --region us-central1
```

## CI/CD Pipeline

Two GitHub Actions workflows automate building and deploying:

### CI Workflow (`.github/workflows/ci.yml`)

Triggers on pushes and PRs to `develop`, `staging`, and `main`:

1. **test** -- Sets up Ruby 3.2.2, creates test DB, runs RSpec and RuboCop, uploads coverage
2. **lint** -- Runs RuboCop in parallel
3. **docker** -- (main branch only) Builds Docker image and pushes to Artifact Registry, tagged with `latest` and the commit SHA

### Deploy Workflow (`.github/workflows/deploy.yml`)

Triggers after a successful CI run on `main`:

1. Authenticates to GCP
2. Updates the Cloud Run Job image to the newly built commit SHA tag

### Flow

```
Push to main --> CI (test + lint + docker build/push) --> Deploy (update Cloud Run Job)
```

### GitHub Secrets Required

Configure these in your repository settings under Settings > Secrets and Variables > Actions:

| Secret | Description |
|--------|-------------|
| `GCP_SA_KEY` | Service account JSON key with permissions for Artifact Registry, Cloud Run, and project access |
| `GCP_PROJECT` | GCP project ID |

To create the service account key:

```bash
# Create a CI/CD service account (separate from the scanner SA)
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions CI/CD"

CI_SA="github-actions@${GCP_PROJECT}.iam.gserviceaccount.com"

# Grant roles
gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${CI_SA}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${CI_SA}" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member="serviceAccount:${CI_SA}" \
  --role="roles/iam.serviceAccountUser"

# Generate key file
gcloud iam service-accounts keys create /tmp/gcp-sa-key.json \
  --iam-account=${CI_SA}

# Set as GitHub secret (using gh CLI)
gh secret set GCP_SA_KEY < /tmp/gcp-sa-key.json
gh secret set GCP_PROJECT --body "$GCP_PROJECT"

# Delete local key file immediately
rm /tmp/gcp-sa-key.json
```

## Monitoring and Logs

### Cloud Run Job Logs

```bash
# View recent job executions
gcloud run jobs executions list --job pentest-scanner \
  --region us-central1

# Stream logs from latest execution
gcloud run jobs executions logs EXECUTION_NAME \
  --region us-central1

# View logs in Cloud Logging (last hour)
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=pentest-scanner" \
  --limit=100 \
  --format="table(timestamp, textPayload)" \
  --freshness=1h
```

### Cloud Logging Queries

In the GCP Console under Logging > Logs Explorer, use these filters:

```
# All scanner logs
resource.type="cloud_run_job"
resource.labels.job_name="pentest-scanner"

# Errors only
resource.type="cloud_run_job"
resource.labels.job_name="pentest-scanner"
severity>=ERROR

# Scan completion messages
resource.type="cloud_run_job"
textPayload:"Scan Complete"
```

### Monitoring Alerts (optional)

Set up alerts for failed job executions:

```bash
gcloud alpha monitoring policies create \
  --display-name="Pentest Scanner Failure" \
  --condition-display-name="Job execution failed" \
  --condition-filter='resource.type="cloud_run_job" AND resource.labels.job_name="pentest-scanner" AND metric.type="run.googleapis.com/job/completed_task_attempt_count" AND metric.labels.result="failed"' \
  --notification-channels=CHANNEL_ID
```

## Email Delivery

Email notifications use **authsmtp.com** on port **2525**:

| Setting | Value |
|---------|-------|
| **SMTP Host** | `mail.authsmtp.com` |
| **SMTP Port** | `2525` |
| **From Address** | Configured via `SMTP_FROM` (default: `pentest@peregrine-tech.com`) |
| **Recipient** | Configured via `NOTIFICATION_EMAIL` |

SMTP credentials are stored in Secret Manager (`pentest-smtp-username`, `pentest-smtp-password`) and injected into the Cloud Run Job at runtime.

## Report Storage

Reports are stored in a GCS bucket named `{project-id}-pentest-reports`.

### Lifecycle Policy

A **90-day lifecycle policy** automatically deletes reports older than 90 days. This is configured in the Pulumi IaC (`infra/main.rb`).

### Accessing Reports

```bash
# List reports
gsutil ls gs://${GCP_PROJECT}-pentest-reports/

# Download a specific report
gsutil cp gs://${GCP_PROJECT}-pentest-reports/path/to/report.html ./

# Download all reports from a scan
gsutil -m cp -r gs://${GCP_PROJECT}-pentest-reports/scans/SCAN_ID/ ./reports/
```

Reports are generated in three formats:
- **JSON** -- Machine-readable findings data
- **HTML** -- Styled report for browser viewing
- **PDF** -- Print-ready report (generated via Grover/Chromium)

## Rollback Procedure

If a new deployment introduces issues, roll back to the previous image:

```bash
# List recent image tags
gcloud artifacts docker tags list \
  us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest/scanner

# Roll back to a specific commit SHA tag
gcloud run jobs update pentest-scanner \
  --image us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest/scanner:PREVIOUS_COMMIT_SHA \
  --region us-central1

# Or roll back to the previous latest
# (if you tagged a known-good version)
gcloud run jobs update pentest-scanner \
  --image us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest/scanner:stable \
  --region us-central1
```

### Verify Rollback

```bash
# Trigger a manual execution to verify
gcloud run jobs execute pentest-scanner --region us-central1

# Check execution status
gcloud run jobs executions list --job pentest-scanner --region us-central1 --limit 3
```

## Cost Estimate

Estimated monthly costs for weekly scans (one execution per week, ~1 hour each):

| Component | Estimated Cost |
|-----------|---------------|
| Cloud Run Jobs (4 vCPU, 16GB, ~4 hrs/mo) | ~$1.50 |
| Cloud Storage (reports, small volume) | ~$0.10 |
| Artifact Registry (image storage) | ~$0.50 |
| Cloud Scheduler | Free tier |
| Secret Manager (6 secrets) | Free tier |
| **Total** | **~$4-5/month** |

Costs scale linearly with scan frequency. Daily scans would be approximately $10-15/month. Actual costs depend on scan duration and report sizes.

## Troubleshooting

### Job Fails Immediately

- Check that all required secrets exist in Secret Manager and have at least one version
- Verify the service account has `roles/secretmanager.secretAccessor`
- Check the Docker image exists in Artifact Registry

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest
```

### Job Times Out (3600s)

- The `thorough` scan profile against large targets can exceed 1 hour
- Switch to `standard` or `quick` profile
- Or increase timeout in `infra/main.rb` and run `pulumi up`

### Scheduler Not Triggering

```bash
# Check scheduler status
gcloud scheduler jobs describe pentest-scanner-schedule --region us-central1

# Verify it is not paused
gcloud scheduler jobs resume pentest-scanner-schedule --region us-central1

# Test trigger manually
gcloud scheduler jobs run pentest-scanner-schedule --region us-central1
```

### Docker Build Fails in CI

- Verify `GCP_SA_KEY` secret is set and the key is valid (not expired)
- Ensure the service account has `roles/artifactregistry.writer`
- Check GitHub Actions logs for authentication errors

### No Reports in GCS

- Verify `GCS_BUCKET` environment variable is set on the Cloud Run Job
- Check that the scanner service account has `roles/storage.objectAdmin` on the bucket
- Reports may be stored locally in the container if GCS is not configured (check container logs)

### Email Notifications Not Sending

- Verify SMTP credentials in Secret Manager are correct
- Confirm authsmtp.com account is active
- Port 2525 must not be blocked by VPC firewall rules (Cloud Run uses public internet, so this is typically not an issue)
- Check logs for SMTP connection errors

### Scanner Tool Not Found in Container

- The Docker image bundles all tools in a multi-stage build
- If a tool is missing, rebuild the image: `docker build -f docker/Dockerfile -t pentest-platform .`
- Check tool installation in the `tools` stage of `docker/Dockerfile`

### Database Errors

- The platform uses SQLite, which is created during Docker image build (`db:create db:migrate`)
- The database is ephemeral -- it is recreated on each container start
- This is by design: each scan execution is independent
