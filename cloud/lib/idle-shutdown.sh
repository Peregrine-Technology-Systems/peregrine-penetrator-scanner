#!/usr/bin/env bash
# Idle shutdown check — installed on VM by setup-vm.sh
# Runs every 5 minutes via cron, shuts down VM after 10 min idle

IDLE_FILE="/tmp/pentest-idle-since"
THRESHOLD_SECONDS=600  # 10 minutes

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
  logger "pentest-idle-shutdown: VM idle for ${idle_seconds}s, shutting down"
  rm -f "$IDLE_FILE"
  /sbin/shutdown -h now "Auto-shutdown: idle for 10+ minutes"
fi
