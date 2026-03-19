#!/usr/bin/env bash
# Idle shutdown check — installed on VM by setup-vm.sh
# This is a standalone copy for reference/manual install
# Runs every 5 minutes via cron, shuts down VM after 30 min idle

IDLE_FILE="/tmp/pentest-idle-since"
THRESHOLD_SECONDS=600  # 10 minutes

# Check for active SSH sessions
ssh_sessions=$(who | wc -l)

# Check for running containers (excluding paused)
running_containers=$(docker ps -q --filter "status=running" 2>/dev/null | wc -l)

# Check for active buildx processes
buildx_active=$(pgrep -c buildx 2>/dev/null || echo 0)

if [ "$ssh_sessions" -gt 0 ] || [ "$running_containers" -gt 0 ] || [ "$buildx_active" -gt 0 ]; then
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
  /sbin/shutdown -h now "Auto-shutdown: idle for 30+ minutes"
fi
