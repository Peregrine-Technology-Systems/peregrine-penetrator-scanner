#!/usr/bin/env bash
# One-time VM provisioning: Docker, disk mount, BuildKit, idle-shutdown cron
# Run as root on the VM
set -euo pipefail

DATA_DISK_DEVICE="/dev/disk/by-id/google-pentest-data"
DATA_MOUNT="/mnt/pentest-data"

echo "=== Setting up pentest dev VM ==="

# 1. Install Docker
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  echo "Docker installed"
else
  echo "Docker already installed"
fi

# Add current user to docker group
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
usermod -aG docker "$REAL_USER" 2>/dev/null || true

# 2. Format and mount persistent data disk
mkdir -p "${DATA_MOUNT}"

if ! mount | grep -q "${DATA_MOUNT}"; then
  # Check if disk has a filesystem
  if ! blkid "${DATA_DISK_DEVICE}" &>/dev/null; then
    echo "Formatting data disk..."
    mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0 "${DATA_DISK_DEVICE}"
  fi

  echo "Mounting data disk at ${DATA_MOUNT}..."
  mount -o discard,defaults "${DATA_DISK_DEVICE}" "${DATA_MOUNT}"

  # Add to fstab for auto-mount on restart
  if ! grep -q "${DATA_MOUNT}" /etc/fstab; then
    echo "${DATA_DISK_DEVICE} ${DATA_MOUNT} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi
else
  echo "Data disk already mounted"
fi

# Create data directories (777 on buildkit-cache: buildx container runs as non-root)
mkdir -p "${DATA_MOUNT}/docker"
mkdir -p "${DATA_MOUNT}/scan-results"
mkdir -p "${DATA_MOUNT}/buildkit-cache"
chmod 777 "${DATA_MOUNT}/buildkit-cache"

# 3. Configure Docker to use persistent disk for storage
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DATA_MOUNT}/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl restart docker
echo "Docker configured with data-root at ${DATA_MOUNT}/docker"

# 4. Configure Docker credential helper for Artifact Registry
if ! command -v docker-credential-gcloud &>/dev/null; then
  # gcloud is pre-installed on GCP VMs
  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet 2>/dev/null || true
fi

# 5. Install idle-shutdown cron
IDLE_SCRIPT="/usr/local/bin/idle-shutdown-check.sh"
cat > "${IDLE_SCRIPT}" <<'IDLE_EOF'
#!/usr/bin/env bash
# Check if VM is idle and shut down if so
# Runs every 5 minutes via cron

IDLE_FILE="/tmp/pentest-idle-since"
THRESHOLD_SECONDS=600  # 10 minutes

# Check for active SSH sessions
ssh_sessions=$(who | wc -l)

# Check for running containers (excluding paused)
running_containers=$(docker ps -q --filter "status=running" 2>/dev/null | wc -l)

# Check for recent docker build activity
docker_building=$(docker ps -q --filter "label=com.docker.compose.project" 2>/dev/null | wc -l)
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
IDLE_EOF

chmod +x "${IDLE_SCRIPT}"

# Install cron job (every 5 minutes)
CRON_ENTRY="*/5 * * * * ${IDLE_SCRIPT}"
(crontab -l 2>/dev/null | grep -v idle-shutdown-check; echo "${CRON_ENTRY}") | crontab -
echo "Idle-shutdown cron installed (30 min threshold)"

# 6. Install rsync (for code sync)
apt-get install -y rsync

echo "=== VM setup complete ==="
echo "Docker data-root: ${DATA_MOUNT}/docker"
echo "Scan results: ${DATA_MOUNT}/scan-results"
echo "BuildKit cache: ${DATA_MOUNT}/buildkit-cache"
