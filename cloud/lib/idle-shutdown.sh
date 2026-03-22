#!/usr/bin/env bash
# Idle shutdown check — installed on VM by setup-vm.sh
# Runs every 5 minutes via cron, shuts down VM after 10 min idle

# Explicit PATH for cron environment (cron uses minimal /usr/bin:/bin)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

IDLE_FILE="/tmp/pentest-idle-since"
BOOT_TIME_FILE="/tmp/pentest-boot-time"
THRESHOLD_SECONDS=600  # 10 minutes

log() { logger "pentest-idle-shutdown: $*"; }

# Record boot time on first run
if [ ! -f "$BOOT_TIME_FILE" ]; then
  date +%s > "$BOOT_TIME_FILE"
fi

# Check for active SSH sessions
ssh_sessions=$(who | wc -l)

# Check for running workload containers (exclude BuildKit infrastructure)
workload_containers=$(docker ps -q --filter "status=running" 2>/dev/null \
  | xargs -r docker inspect --format '{{.Name}}' 2>/dev/null \
  | grep -cv "buildx_buildkit" || echo 0)

if [ "$ssh_sessions" -gt 0 ] || [ "$workload_containers" -gt 0 ]; then
  # VM is active — reset idle timer
  rm -f "$IDLE_FILE"
  exit 0
fi

# VM appears idle
if [ ! -f "$IDLE_FILE" ]; then
  date +%s > "$IDLE_FILE"
  exit 0
fi

idle_since=$(cat "$IDLE_FILE")
now=$(date +%s)
idle_seconds=$((now - idle_since))

if [ "$idle_seconds" -ge "$THRESHOLD_SECONDS" ]; then
  # Calculate total runtime
  boot_time=$(cat "$BOOT_TIME_FILE" 2>/dev/null || echo "$now")
  runtime_seconds=$((now - boot_time))
  runtime_hours=$((runtime_seconds / 3600))
  runtime_minutes=$(((runtime_seconds % 3600) / 60))

  log "idle ${idle_seconds}s, runtime ${runtime_hours}h ${runtime_minutes}m — sending notification"

  # Send Slack notification (with timeouts to prevent hanging)
  WEBHOOK_URL=$(curl --max-time 5 -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/SLACK_WEBHOOK_URL" 2>/dev/null || echo "")

  if [ -n "$WEBHOOK_URL" ]; then
    HOSTNAME=$(hostname)
    SLACK_RESPONSE=$(curl --max-time 10 -sf -X POST -H 'Content-type: application/json' \
      --data "{\"text\": \":stop_sign: Dev VM \`${HOSTNAME}\` stopping (idle 10 min). Total runtime: ${runtime_hours}h ${runtime_minutes}m\"}" \
      "$WEBHOOK_URL" 2>&1) && \
      log "Slack notification sent: ${SLACK_RESPONSE}" || \
      log "Slack notification FAILED: ${SLACK_RESPONSE}"
    # Allow network buffer to flush
    sleep 2
  else
    log "No SLACK_WEBHOOK_URL in metadata — skipping notification"
  fi

  log "shutting down"
  rm -f "$IDLE_FILE" "$BOOT_TIME_FILE"
  /sbin/shutdown -h now "Auto-shutdown: idle for 10+ minutes"
fi
