#!/usr/bin/env bash
# Sync project code to VM via differential tar and run docker build
set -euo pipefail
source "$(dirname "$0")/config.sh"

PUSH=false
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=true ;;
  esac
done

# Ensure VM is running
status=$(vm_status)
if [ "$status" != "RUNNING" ]; then
  log_error "VM is not running (status: ${status:-not found})"
  log_info "Run './cloud/dev start' first"
  exit 1
fi

# --- Differential tar sync ---
SNAPSHOT_FILE="${CLOUD_DIR}/.sync-snapshot"
TAR_EXCLUDES=(
  --exclude='.git'
  --exclude='tmp'
  --exclude='log'
  --exclude='coverage'
  --exclude='node_modules'
  --exclude='vendor/bundle'
  --exclude='storage'
  --exclude='.env'
  --exclude='.env.*'
  --exclude='cloud/.sync-snapshot'
)

LOCAL_TAR=$(mktemp /tmp/pentest-sync.XXXXXX.tar.gz)
trap "rm -f '$LOCAL_TAR'" EXIT

# Try differential tar first (only files changed since last sync)
if [ -f "$SNAPSHOT_FILE" ]; then
  log_info "Creating differential tar (changes since last sync)..."
  if tar czf "$LOCAL_TAR" \
      "${TAR_EXCLUDES[@]}" \
      --newer-mtime="$(cat "$SNAPSHOT_FILE")" \
      -C "${PROJECT_ROOT}" . 2>/dev/null; then

    # Check if the tar actually has content (not just headers)
    TAR_SIZE=$(wc -c < "$LOCAL_TAR" | tr -d ' ')
    if [ "$TAR_SIZE" -gt 100 ]; then
      log_info "Differential tar: $(du -h "$LOCAL_TAR" | cut -f1)"
    else
      log_info "No changes detected, skipping sync"
      date -u +"%Y-%m-%d %H:%M:%S" > "$SNAPSHOT_FILE"
      LOCAL_TAR=""
    fi
  else
    log_warn "Differential tar failed, falling back to full sync"
    rm -f "$LOCAL_TAR"
    LOCAL_TAR=$(mktemp /tmp/pentest-sync.XXXXXX.tar.gz)
    tar czf "$LOCAL_TAR" "${TAR_EXCLUDES[@]}" -C "${PROJECT_ROOT}" .
    log_info "Full tar: $(du -h "$LOCAL_TAR" | cut -f1)"
  fi
else
  log_info "First sync — creating full tar..."
  tar czf "$LOCAL_TAR" "${TAR_EXCLUDES[@]}" -C "${PROJECT_ROOT}" .
  log_info "Full tar: $(du -h "$LOCAL_TAR" | cut -f1)"
fi

# Upload and extract on VM
if [ -n "$LOCAL_TAR" ]; then
  vm_ssh "mkdir -p ~/pentest-platform"
  vm_scp "$LOCAL_TAR" "${VM_NAME}:~/pentest-sync.tar.gz"
  vm_ssh "tar xzf ~/pentest-sync.tar.gz -C ~/pentest-platform && rm ~/pentest-sync.tar.gz"
  log_ok "Code synced"
fi

# Record sync timestamp
date -u +"%Y-%m-%d %H:%M:%S" > "$SNAPSHOT_FILE"

# --- Docker build on VM ---
PUSH_FLAG=""
LOAD_FLAG="--load"
if [ "$PUSH" = true ]; then
  PUSH_FLAG="--push"
  LOAD_FLAG=""
  log_info "Building and pushing image to ${FULL_IMAGE}..."
else
  log_info "Building image on VM..."
fi

vm_ssh "cd ~/pentest-platform && \
  docker buildx create --name pentest-builder --use 2>/dev/null || docker buildx use pentest-builder 2>/dev/null || true && \
  docker buildx build \
    --cache-from type=local,src=${DATA_MOUNT_POINT}/buildkit-cache \
    --cache-to type=local,dest=${DATA_MOUNT_POINT}/buildkit-cache,mode=max \
    -f docker/Dockerfile \
    -t ${FULL_IMAGE} \
    ${LOAD_FLAG} ${PUSH_FLAG} \
    ."

log_ok "Build complete"
if [ "$PUSH" = true ]; then
  log_ok "Image pushed to ${FULL_IMAGE}"
fi
