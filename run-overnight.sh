#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
export MAX_JOBS="${MAX_JOBS:-3}"
export BUILD_CORES="${BUILD_CORES:-1}"
SLEEP_AFTER_LOW_DISK="${SLEEP_AFTER_LOW_DISK:-300}"

free_root_gib() {
  df -Pk / | awk 'NR == 2 { print int($4 / 1024 / 1024) }'
}

echo "[$(date)] Overnight runner starting."
echo "[$(date)] Settings: MIN_FREE_GIB=$MIN_FREE_GIB MAX_JOBS=$MAX_JOBS BUILD_CORES=$BUILD_CORES"

while true; do
  echo "[$(date)] Running nix-store --gc before push attempt..."
  nix-store --gc || true
  echo "[$(date)] Disk before push: / has $(free_root_gib) GiB free."

  set +e
  "$DIR/push.sh"
  status="$?"
  set -e

  if [ "$status" -eq 0 ]; then
    echo "[$(date)] push.sh completed successfully."
    exit 0
  fi

  if [ "$status" -eq 75 ]; then
    echo "[$(date)] push.sh stopped due to low disk. Running GC and retrying after ${SLEEP_AFTER_LOW_DISK}s..."
    nix-store --gc || true
    echo "[$(date)] Disk after low-disk GC: / has $(free_root_gib) GiB free."
    sleep "$SLEEP_AFTER_LOW_DISK"
    continue
  fi

  echo "[$(date)] push.sh exited with unexpected status $status; not retrying automatically."
  exit "$status"
done
