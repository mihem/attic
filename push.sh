#!/usr/bin/env bash
set -euo pipefail

CACHE="r-packages"
ATTIC_DB="/var/lib/attic/server.db"
NIX="${NIX:-$(command -v nix || printf '/nix/var/nix/profiles/default/bin/nix')}"
NIX_STORE="${NIX_STORE:-$(command -v nix-store || printf '/nix/var/nix/profiles/default/bin/nix-store')}"
export R_NIXPKGS_DATE="${R_NIXPKGS_DATE:-2026-05-18}"
MAX_JOBS="${MAX_JOBS:-6}"
BUILD_CORES="${BUILD_CORES:-1}"
MIN_FREE_GIB="${MIN_FREE_GIB:-30}"
DISK_CHECK_INTERVAL="${DISK_CHECK_INTERVAL:-60}"
NIX_STORE_GC_AFTER="${NIX_STORE_GC_AFTER:-1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPR="${EXPR:-$DIR/packages.nix}"
ATTR="${ATTR:-rPackagesSet}"
LOGDIR="$DIR/logs"
LOG="$LOGDIR/build-$(date +%Y-%m-%d_%H%M%S).log"
RESULTS_JSON="$DIR/results.json"
BUILT_PATHS_FILE="$DIR/built-paths.txt"
LOW_DISK_FILE="$DIR/.push-low-disk"

free_root_kib() {
  df -Pk / | awk 'NR == 2 { print $4 }'
}

free_root_gib() {
  echo $(( $(free_root_kib) / 1024 / 1024 ))
}

check_root_space() {
  local free_kib min_kib
  free_kib="$(free_root_kib)"
  min_kib=$(( MIN_FREE_GIB * 1024 * 1024 ))
  if [ "$free_kib" -lt "$min_kib" ]; then
    echo "[$(date)] ERROR: / has only $(( free_kib / 1024 / 1024 )) GiB free; threshold is ${MIN_FREE_GIB} GiB."
    return 1
  fi
}

monitor_root_space() {
  local pid="$1"
  while kill -0 "$pid" 2>/dev/null; do
    if ! check_root_space; then
      echo "[$(date)] Low disk guard stopping nix-fast-build pid $pid."
      : > "$LOW_DISK_FILE"
      kill "$pid" 2>/dev/null || true
      sleep 20
      kill -KILL "$pid" 2>/dev/null || true
      return 0
    fi
    sleep "$DISK_CHECK_INTERVAL"
  done
}

run_nix_store_gc() {
  echo "[$(date)] Running nix-store --gc to free local /nix/store space..."
  "$NIX_STORE" --gc || true
  echo "[$(date)] Disk after GC: / has $(free_root_gib) GiB free."
}

mkdir -p "$LOGDIR"
# Filter out annoying and harmless Nix warnings (e.g. unknown settings) from the output in real-time
exec > >(grep --line-buffered -v "unknown setting" | tee -a "$LOG") 2>&1

echo "[$(date)] Source date: R_NIXPKGS_DATE=$R_NIXPKGS_DATE"
echo "[$(date)] Build limits: max_jobs=$MAX_JOBS build_cores=$BUILD_CORES"
echo "[$(date)] Build target: expr=$EXPR attr=$ATTR"
echo "[$(date)] Disk guard: stop if / has less than ${MIN_FREE_GIB} GiB free; current free: $(free_root_gib) GiB"
rm -f "$LOW_DISK_FILE"
check_root_space || exit 75

## ── 1. Build individual packages with nix-fast-build ──────
echo "[$(date)] Running nix-fast-build to build all individual packages..."
RUN_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"
"$NIX" run .#nix-fast-build -- \
  --file "$EXPR" \
  -A "$ATTR" \
  --max-jobs "$MAX_JOBS" \
  --option cores "$BUILD_CORES" \
  --result-file "$RESULTS_JSON" \
  --no-link \
  --skip-cached \
  --attic-cache "$CACHE" \
  --no-nom &
NIX_FAST_BUILD_PID="$!"
monitor_root_space "$NIX_FAST_BUILD_PID" &
DISK_MONITOR_PID="$!"
set +e
wait "$NIX_FAST_BUILD_PID"
NIX_FAST_BUILD_STATUS="$?"
set -e
kill "$DISK_MONITOR_PID" 2>/dev/null || true
wait "$DISK_MONITOR_PID" 2>/dev/null || true

if [ -e "$LOW_DISK_FILE" ]; then
  echo "[$(date)] Stopped because the root filesystem crossed the low-disk threshold."
  [ "$NIX_STORE_GC_AFTER" = "1" ] && run_nix_store_gc
  rm -f "$LOW_DISK_FILE"
  exit 75
fi

if [ "$NIX_FAST_BUILD_STATUS" -ne 0 ]; then
  echo "[$(date)] nix-fast-build exited with status $NIX_FAST_BUILD_STATUS; continuing to summarize results."
fi

# ── 2. Run update-blacklist and output built paths ───────────────────────────
echo "[$(date)] Updating blacklist and finding active local paths..."
python3 "$DIR/update-blacklist.py" "$RESULTS_JSON" "$DIR/blacklist.txt" "$BUILT_PATHS_FILE"

# ── 3. Report successful local paths and upload/build summary ────────────────
if [ -s "$BUILT_PATHS_FILE" ]; then
  echo "[$(date)] nix-fast-build produced these active local paths."
  cp "$BUILT_PATHS_FILE" "$LOGDIR/built-paths-$(date +%Y-%m-%d_%H%M%S).txt"
else
  echo "[$(date)] No active local store paths detected. Attic cache is already up-to-date!"
fi

python3 "$DIR/summarize-results.py" "$RESULTS_JSON"

echo "Attic growth since run start:"
sudo sqlite3 -readonly "$ATTIC_DB" "
  select '  Attic newly uploaded paths: ' || count(*)
    from nar
    where created_at >= '$RUN_STARTED_AT';
  select '  Attic newly uploaded logical size: ' || printf('%.2f GiB', coalesce(sum(nar_size), 0) / 1024.0 / 1024 / 1024)
    from nar
    where created_at >= '$RUN_STARTED_AT';
  select '  Attic newly stored chunks: ' || count(*)
    from chunk
    where created_at >= '$RUN_STARTED_AT';
  select '  Attic newly stored size: ' || printf('%.2f GiB', coalesce(sum(file_size), 0) / 1024.0 / 1024 / 1024)
    from chunk
    where created_at >= '$RUN_STARTED_AT';
"

echo "[$(date)] Clearing stored Attic object signatures..."
if ! sudo sqlite3 -cmd ".timeout 60000" "$ATTIC_DB" "
    select count(*) || ' stored signatures before cleanup' from object where sigs != '[]';
    select store_path from object where sigs != '[]' order by store_path;
    update object set sigs = '[]' where sigs != '[]';
    select changes() || ' stored signatures cleared';
    select count(*) || ' stored signatures after cleanup' from object where sigs != '[]';
  "; then
  echo "[$(date)] Warning: stored Attic object signature cleanup failed; continuing."
fi

# ── 4. Clean up ───────────────────────────────────────────────────────────────
rm -f "$BUILT_PATHS_FILE" "$RESULTS_JSON"
[ "$NIX_STORE_GC_AFTER" = "1" ] && run_nix_store_gc
echo "[$(date)] Done."
