#!/usr/bin/env bash
set -euo pipefail

# Benchmark Attic push performance for a few NFS-friendly chunking settings.
# Run this on the Attic server. It creates temporary benchmark caches and
# synthetic Nix store paths, then restores /etc/attic/server.toml on exit.

ATTIC=${ATTIC:-/etc/attic/attic-client-bin/bin/attic}
CONFIG=${CONFIG:-/etc/attic/server.toml}
SERVICE=${SERVICE:-attic-server.service}
KEY=${KEY:-/etc/attic/signing-key.sec}
LOGDIR=${LOGDIR:-./logs}

PATH_COUNT=${PATH_COUNT:-8}
COMMON_MIB=${COMMON_MIB:-16}
UNIQUE_MIB=${UNIQUE_MIB:-48}
SAMPLE_MODE=${SAMPLE_MODE:-real}
BENCHMARK_KIND=${BENCHMARK_KIND:-single}
CHANGE_MODE=${CHANGE_MODE:-medium}
REAL_MIN_MIB=${REAL_MIN_MIB:-20}
REAL_MAX_MIB=${REAL_MAX_MIB:-150}
REAL_PATHS_FILE=${REAL_PATHS_FILE:-}
PRESETS=${PRESETS:-nochunk,chunk-4m,chunk-8m,chunk-16m,chunk-32m}
JOBS=${JOBS:-8}
NO_CLOSURE=${NO_CLOSURE:-1}
KEEP_CACHES=${KEEP_CACHES:-0}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}

if ! command -v nix-store >/dev/null 2>&1 && [ -r /etc/profile.d/nix.sh ]; then
  # Non-interactive SSH sessions often do not load the Nix profile.
  . /etc/profile.d/nix.sh
fi

if ! command -v nix-store >/dev/null 2>&1 && [ -x /nix/var/nix/profiles/default/bin/nix-store ]; then
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

mkdir -p "$LOGDIR"
LOG="$LOGDIR/attic-push-benchmark-$RUN_ID.log"
SUMMARY="$LOGDIR/attic-push-benchmark-$RUN_ID.tsv"
TMPDIR=$(mktemp -d)
BACKUP="$TMPDIR/server.toml.orig"
CACHES_CREATED="$TMPDIR/caches-created.txt"

cleanup() {
  set +e
  if [ -f "$BACKUP" ]; then
    echo "[$(date)] Restoring $CONFIG" | tee -a "$LOG"
    sudo cp "$BACKUP" "$CONFIG"
    sudo systemctl restart "$SERVICE"
  fi
  if [ "$KEEP_CACHES" != "1" ] && [ -f "$CACHES_CREATED" ]; then
    while IFS= read -r cache; do
      [ -n "$cache" ] || continue
      echo "[$(date)] Destroying temporary cache $cache" | tee -a "$LOG"
      "$ATTIC" cache destroy "$cache" --no-confirm >> "$LOG" 2>&1 || true
    done < "$CACHES_CREATED"
  fi
  if [ -d "$TMPDIR" ]; then
    chmod -R u+w "$TMPDIR" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage: $0

Environment overrides:
  PATH_COUNT=8       Number of synthetic store paths per preset
  COMMON_MIB=16      Repeated data MiB per path
  UNIQUE_MIB=48      Unique data MiB per path
  SAMPLE_MODE=real   real or synthetic
  BENCHMARK_KIND=single  single or delta
  CHANGE_MODE=medium     small or medium, for BENCHMARK_KIND=delta
  REAL_MIN_MIB=20    Minimum R package NAR size for real samples
  REAL_MAX_MIB=150   Maximum R package NAR size for real samples
  REAL_PATHS_FILE=   Optional TSV/list of exact real store paths to copy
  PRESETS=nochunk,chunk-4m,chunk-8m,chunk-16m,chunk-32m
          For BENCHMARK_KIND=delta, also supports avg512k,avg1m,avg2m,avg4m
  JOBS=8             attic push --jobs value
  NO_CLOSURE=1       Push exact benchmark paths only, not their closures
  KEEP_CACHES=0      Set to 1 to keep temporary benchmark caches
  ATTIC=$ATTIC
  CONFIG=$CONFIG
  SERVICE=$SERVICE
  KEY=$KEY
  LOGDIR=$LOGDIR

Presets tested:
  nochunk     threshold=0,        avg=64KiB   (dedup disabled)
  chunk-4m    threshold=4MiB,     avg=1MiB
  chunk-8m    threshold=8MiB,     avg=1MiB
  chunk-16m   threshold=16MiB,    avg=1MiB
  chunk-32m   threshold=32MiB,    avg=1MiB
  avg512k     threshold=16MiB,    avg=512KiB
  avg1m       threshold=16MiB,    avg=1MiB
  avg2m       threshold=16MiB,    avg=2MiB
  avg4m       threshold=16MiB,    avg=4MiB

With SAMPLE_MODE=real, the script samples existing R package paths, copies
their contents into fresh Nix store paths, and pushes those fresh paths. It
does not touch the real r-packages cache.

With BENCHMARK_KIND=delta, the script pushes two fresh versions of the same
sampled real package contents into one temporary cache per preset. The second
version simulates a weekly update and reports only newly added storage.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

require_cmd dd
require_cmd nix-store
require_cmd sqlite3
require_cmd sudo

if [ ! -x "$ATTIC" ]; then
  echo "Attic client not executable: $ATTIC" >&2
  exit 1
fi

sudo test -r "$CONFIG"
sudo cp "$CONFIG" "$BACKUP"

if [ "$BENCHMARK_KIND" = "delta" ]; then
  cat > "$SUMMARY" <<'EOF'
preset	cache	paths	logical_mib	v1_seconds	v1_new_chunks	v1_new_chunk_mib	v2_seconds	v2_new_chunks	v2_new_chunk_mib	status
EOF
else
  cat > "$SUMMARY" <<'EOF'
preset	cache	paths	logical_mib	seconds	new_nars	new_chunks	new_chunk_mib	status
EOF
fi

REAL_SOURCES="$TMPDIR/real-sources.tsv"

log() {
  echo "[$(date)] $*" | tee -a "$LOG"
}

db_scalar() {
  sudo sqlite3 /var/lib/attic/server.db "$1"
}

db_stats() {
  db_scalar "select (select count(*) from nar) || ' ' || (select count(*) from chunk) || ' ' || coalesce((select sum(chunk_size) from chunk), 0);"
}

select_real_sources() {
  local candidates="$TMPDIR/real-candidates.tsv"
  local path mib selected=0 total_mib=0

  if [ -n "$REAL_PATHS_FILE" ]; then
    : > "$REAL_SOURCES"
    while IFS=$'\t' read -r path mib _; do
      [ -n "$path" ] || continue
      if [ -z "${mib:-}" ]; then
        mib=$(nix path-info -S "$path" 2>/dev/null | awk '{print int(($2 + 1048575) / 1048576)}')
      fi
      if [ -e "$path" ]; then
        printf '%s\t%s\n' "$path" "$mib" >> "$REAL_SOURCES"
        selected=$((selected + 1))
        total_mib=$((total_mib + mib))
      fi
    done < "$REAL_PATHS_FILE"
    PATH_COUNT=$selected
    if [ "$selected" -eq 0 ]; then
      echo "No existing paths found in REAL_PATHS_FILE=$REAL_PATHS_FILE" >&2
      exit 1
    fi
    log "Selected $selected exact real paths, about ${total_mib}MiB total size"
    tee -a "$LOG" < "$REAL_SOURCES" >/dev/null
    return
  fi

  sudo sqlite3 -tabs /var/lib/attic/server.db \
    "select store_path, cast(round(nar_size/1024.0/1024) as integer) from object join nar on nar.id=object.nar_id where store_path like '%-r-%' and nar_size between $((REAL_MIN_MIB * 1024 * 1024)) and $((REAL_MAX_MIB * 1024 * 1024)) order by nar_size desc;" \
    > "$candidates"

  : > "$REAL_SOURCES"
  while IFS=$'\t' read -r path mib; do
    if [ -e "$path" ]; then
      printf '%s\t%s\n' "$path" "$mib" >> "$REAL_SOURCES"
      selected=$((selected + 1))
      total_mib=$((total_mib + mib))
      if [ "$selected" -ge "$PATH_COUNT" ]; then
        break
      fi
    fi
  done < "$candidates"

  if [ "$selected" -lt "$PATH_COUNT" ]; then
    echo "Only found $selected existing R package paths in ${REAL_MIN_MIB}-${REAL_MAX_MIB}MiB range; need PATH_COUNT=$PATH_COUNT" >&2
    exit 1
  fi

  log "Selected $selected real R package paths, about ${total_mib}MiB total NAR size"
  tee -a "$LOG" < "$REAL_SOURCES" >/dev/null
}

apply_chunking() {
  local threshold=$1
  local min_size=$2
  local avg_size=$3
  local max_size=$4

  sudo python3 - "$CONFIG" "$threshold" "$min_size" "$avg_size" "$max_size" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {
    "nar-size-threshold": sys.argv[2],
    "min-size": sys.argv[3],
    "avg-size": sys.argv[4],
    "max-size": sys.argv[5],
}

lines = path.read_text().splitlines()
out = []
in_chunking = False
seen_section = False
seen_keys = set()

def emit_missing():
    for key, value in values.items():
        if key not in seen_keys:
            out.append(f"{key} = {value}")

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_chunking:
            emit_missing()
        in_chunking = stripped == "[chunking]"
        if in_chunking:
            seen_section = True
            seen_keys = set()
        out.append(line)
        continue

    if in_chunking:
        matched = False
        for key, value in values.items():
            if stripped.startswith(key) and "=" in stripped:
                comment = ""
                if "#" in line:
                    comment = " " + line[line.index("#"):]
                out.append(f"{key} = {value}{comment}")
                seen_keys.add(key)
                matched = True
                break
        if matched:
            continue

    out.append(line)

if in_chunking:
    emit_missing()

if not seen_section:
    out.extend(["", "[chunking]"])
    for key, value in values.items():
        out.append(f"{key} = {value}")

path.write_text("\n".join(out) + "\n")
PY
}

make_paths() {
  local preset=$1
  local dir common payload store_path i
  local paths_file="$TMPDIR/paths-$preset.txt"
  local logical_mib_file="$TMPDIR/logical-$preset.txt"

  : > "$paths_file"
  common="$TMPDIR/common-$preset.bin"
  dd if=/dev/urandom of="$common" bs=1M count="$COMMON_MIB" status=none

  for i in $(seq 1 "$PATH_COUNT"); do
    dir="$TMPDIR/input-$preset-$i"
    mkdir -p "$dir"
    cp "$common" "$dir/common.bin"
    payload="$dir/unique.bin"
    dd if=/dev/urandom of="$payload" bs=1M count="$UNIQUE_MIB" status=none
    printf '%s\n%s\n' "$preset" "$i" > "$dir/metadata.txt"
    store_path=$(nix-store --add "$dir")
    echo "$store_path" >> "$paths_file"
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "$dir"
  done

  echo "$((PATH_COUNT * (COMMON_MIB + UNIQUE_MIB)))" > "$logical_mib_file"
  echo "$paths_file"
}

make_real_paths() {
  local preset=$1
  local paths_file="$TMPDIR/paths-$preset.txt"
  local logical_mib_file="$TMPDIR/logical-$preset.txt"
  local src mib dir store_path i=0 total_mib=0

  : > "$paths_file"
  while IFS=$'\t' read -r src mib; do
    i=$((i + 1))
    total_mib=$((total_mib + mib))
    dir="$TMPDIR/input-$preset-$i"
    mkdir -p "$dir"
    cp -a "$src" "$dir/payload"
    printf 'preset=%s\nindex=%s\nsource=%s\nrun_id=%s\n' "$preset" "$i" "$src" "$RUN_ID" > "$dir/benchmark-metadata.txt"
    store_path=$(nix-store --add "$dir")
    echo "$store_path" >> "$paths_file"
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "$dir"
  done < "$REAL_SOURCES"

  echo "$total_mib" > "$logical_mib_file"
  echo "$paths_file"
}

mutate_delta_tree() {
  local dir=$1
  local preset=$2
  local index=$3

  printf 'preset=%s\nindex=%s\nrun_id=%s\nchange_mode=%s\nchanged_at=%s\n' \
    "$preset" "$index" "$RUN_ID" "$CHANGE_MODE" "$(date +%s%N)" >> "$dir/benchmark-metadata.txt"

  if [ "$CHANGE_MODE" = "medium" ]; then
    python3 - "$dir/payload" <<'PY'
import os
import sys

root = sys.argv[1]
files = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        if size >= 1024 * 1024:
            files.append((size, path))

files.sort(reverse=True)
payload = os.urandom(64 * 1024)
for _, path in files[:3]:
    try:
        with open(path, "ab") as f:
            f.write(payload)
    except OSError:
        pass
PY
  elif [ "$CHANGE_MODE" != "small" ]; then
    echo "Unsupported CHANGE_MODE=$CHANGE_MODE; expected small or medium" >&2
    exit 1
  fi
}

make_delta_real_paths() {
  local preset=$1
  local version=$2
  local paths_file="$TMPDIR/paths-$preset-$version.txt"
  local logical_mib_file="$TMPDIR/logical-$preset-$version.txt"
  local src mib dir store_path i=0 total_mib=0

  : > "$paths_file"
  while IFS=$'\t' read -r src mib; do
    i=$((i + 1))
    total_mib=$((total_mib + mib))
    dir="$TMPDIR/input-$preset-$version-$i"
    mkdir -p "$dir"
    cp -a "$src" "$dir/payload"
    chmod -R u+w "$dir" 2>/dev/null || true
    printf 'preset=%s\nversion=%s\nindex=%s\nsource=%s\nrun_id=%s\n' "$preset" "$version" "$i" "$src" "$RUN_ID" > "$dir/benchmark-metadata.txt"
    if [ "$version" = "v2" ]; then
      mutate_delta_tree "$dir" "$preset" "$i"
    fi
    store_path=$(nix-store --add "$dir")
    echo "$store_path" >> "$paths_file"
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "$dir"
  done < "$REAL_SOURCES"

  echo "$total_mib" > "$logical_mib_file"
  echo "$paths_file"
}

run_preset() {
  local preset=$1 threshold=$2 min_size=$3 avg_size=$4 max_size=$5
  local cache="bench-$preset-$RUN_ID"
  local paths_file before after before_nars before_chunks before_bytes after_nars after_chunks after_bytes
  local start end seconds status logical_mib

  log "Applying preset $preset: threshold=$threshold min=$min_size avg=$avg_size max=$max_size"
  apply_chunking "$threshold" "$min_size" "$avg_size" "$max_size"
  sudo systemctl restart "$SERVICE"
  sleep 2
  sudo systemctl is-active --quiet "$SERVICE"

  log "Creating fresh benchmark store paths for $preset"
  if [ "$SAMPLE_MODE" = "real" ]; then
    log "Copying sampled real R package contents for $preset"
    paths_file=$(make_real_paths "$preset")
  elif [ "$SAMPLE_MODE" = "synthetic" ]; then
    paths_file=$(make_paths "$preset")
  else
    echo "Unsupported SAMPLE_MODE=$SAMPLE_MODE; expected real or synthetic" >&2
    exit 1
  fi
  logical_mib=$(cat "$TMPDIR/logical-$preset.txt")

  if [ -f "$KEY" ]; then
    log "Signing benchmark paths for $preset"
    xargs -r nix store sign --key-file "$KEY" < "$paths_file"
  fi

  log "Creating temporary cache $cache"
  "$ATTIC" cache create "$cache" >> "$LOG" 2>&1
  echo "$cache" >> "$CACHES_CREATED"

  before=$(db_stats)
  read -r before_nars before_chunks before_bytes <<< "$before"

  log "Pushing $PATH_COUNT paths (~${logical_mib}MiB logical input) to $cache"
  start=$(date +%s)
  status=ok
  push_args=()
  if [ "$NO_CLOSURE" = "1" ]; then
    push_args+=(--no-closure)
  fi
  if ! "$ATTIC" push "$cache" $(cat "$paths_file") --jobs "$JOBS" "${push_args[@]}" >> "$LOG" 2>&1; then
    status=failed
  fi
  end=$(date +%s)
  seconds=$((end - start))

  after=$(db_stats)
  read -r after_nars after_chunks after_bytes <<< "$after"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$preset" \
    "$cache" \
    "$PATH_COUNT" \
    "$logical_mib" \
    "$seconds" \
    "$((after_nars - before_nars))" \
    "$((after_chunks - before_chunks))" \
    "$(((after_bytes - before_bytes) / 1024 / 1024))" \
    "$status" | tee -a "$SUMMARY"

  if [ "$KEEP_CACHES" != "1" ]; then
    log "Destroying temporary cache $cache"
    "$ATTIC" cache destroy "$cache" --no-confirm >> "$LOG" 2>&1 || true
  else
    log "Keeping temporary cache $cache because KEEP_CACHES=1"
  fi
}

run_delta_preset() {
  local preset=$1 threshold=$2 min_size=$3 avg_size=$4 max_size=$5
  local cache="bench-delta-$preset-$RUN_ID"
  local paths_v1 paths_v2 before after1 after2 before_nars before_chunks before_bytes after1_nars after1_chunks after1_bytes after2_nars after2_chunks after2_bytes
  local start end v1_seconds v2_seconds status logical_mib

  if [ "$SAMPLE_MODE" != "real" ]; then
    echo "BENCHMARK_KIND=delta requires SAMPLE_MODE=real" >&2
    exit 1
  fi

  log "Applying delta preset $preset: threshold=$threshold min=$min_size avg=$avg_size max=$max_size"
  apply_chunking "$threshold" "$min_size" "$avg_size" "$max_size"
  sudo systemctl restart "$SERVICE"
  sleep 2
  sudo systemctl is-active --quiet "$SERVICE"

  log "Creating delta v1 paths for $preset"
  paths_v1=$(make_delta_real_paths "$preset" v1)
  logical_mib=$(cat "$TMPDIR/logical-$preset-v1.txt")
  log "Creating delta v2 paths for $preset with CHANGE_MODE=$CHANGE_MODE"
  paths_v2=$(make_delta_real_paths "$preset" v2)

  if [ -f "$KEY" ]; then
    log "Signing delta benchmark paths for $preset"
    xargs -r nix store sign --key-file "$KEY" < "$paths_v1"
    xargs -r nix store sign --key-file "$KEY" < "$paths_v2"
  fi

  log "Creating temporary cache $cache"
  "$ATTIC" cache create "$cache" >> "$LOG" 2>&1
  echo "$cache" >> "$CACHES_CREATED"

  before=$(db_stats)
  read -r before_nars before_chunks before_bytes <<< "$before"

  log "Pushing v1 $PATH_COUNT paths (~${logical_mib}MiB logical input) to $cache"
  start=$(date +%s)
  status=ok
  push_args=()
  if [ "$NO_CLOSURE" = "1" ]; then
    push_args+=(--no-closure)
  fi
  if ! "$ATTIC" push "$cache" $(cat "$paths_v1") --jobs "$JOBS" "${push_args[@]}" >> "$LOG" 2>&1; then
    status=failed-v1
  fi
  end=$(date +%s)
  v1_seconds=$((end - start))

  after1=$(db_stats)
  read -r after1_nars after1_chunks after1_bytes <<< "$after1"

  log "Pushing v2 $PATH_COUNT paths to $cache"
  start=$(date +%s)
  if [ "$status" = "ok" ] && ! "$ATTIC" push "$cache" $(cat "$paths_v2") --jobs "$JOBS" "${push_args[@]}" >> "$LOG" 2>&1; then
    status=failed-v2
  fi
  end=$(date +%s)
  v2_seconds=$((end - start))

  after2=$(db_stats)
  read -r after2_nars after2_chunks after2_bytes <<< "$after2"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$preset" \
    "$cache" \
    "$PATH_COUNT" \
    "$logical_mib" \
    "$v1_seconds" \
    "$((after1_chunks - before_chunks))" \
    "$(((after1_bytes - before_bytes) / 1024 / 1024))" \
    "$v2_seconds" \
    "$((after2_chunks - after1_chunks))" \
    "$(((after2_bytes - after1_bytes) / 1024 / 1024))" \
    "$status" | tee -a "$SUMMARY"

  if [ "$KEEP_CACHES" != "1" ]; then
    log "Destroying temporary cache $cache"
    "$ATTIC" cache destroy "$cache" --no-confirm >> "$LOG" 2>&1 || true
  else
    log "Keeping temporary cache $cache because KEEP_CACHES=1"
  fi
}

log "Starting Attic push benchmark run $RUN_ID"
log "Detailed log: $LOG"
log "Summary TSV: $SUMMARY"
log "Sample: BENCHMARK_KIND=$BENCHMARK_KIND SAMPLE_MODE=$SAMPLE_MODE CHANGE_MODE=$CHANGE_MODE PATH_COUNT=$PATH_COUNT COMMON_MIB=$COMMON_MIB UNIQUE_MIB=$UNIQUE_MIB REAL_MIN_MIB=$REAL_MIN_MIB REAL_MAX_MIB=$REAL_MAX_MIB REAL_PATHS_FILE=$REAL_PATHS_FILE PRESETS=$PRESETS JOBS=$JOBS NO_CLOSURE=$NO_CLOSURE"

if [ "$SAMPLE_MODE" = "real" ]; then
  select_real_sources
fi

if [ "$BENCHMARK_KIND" = "delta" ]; then
  if [[ ",$PRESETS," == *,nochunk,* ]]; then
    run_delta_preset nochunk 0 16384 65536 262144
  fi
  if [[ ",$PRESETS," == *,chunk-4m,* ]]; then
    run_delta_preset chunk-4m 4194304 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-8m,* ]]; then
    run_delta_preset chunk-8m 8388608 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-16m,* ]]; then
    run_delta_preset chunk-16m 16777216 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-32m,* ]]; then
    run_delta_preset chunk-32m 33554432 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,avg512k,* ]]; then
    run_delta_preset avg512k 16777216 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,avg1m,* ]]; then
    run_delta_preset avg1m 16777216 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,avg2m,* ]]; then
    run_delta_preset avg2m 16777216 524288 2097152 8388608
  fi
  if [[ ",$PRESETS," == *,avg4m,* ]]; then
    run_delta_preset avg4m 16777216 1048576 4194304 16777216
  fi
  if [[ ",$PRESETS," == *,th16-512k,* ]]; then
    run_delta_preset th16-512k 16777216 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,th16-1m,* ]]; then
    run_delta_preset th16-1m 16777216 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,th8-512k,* ]]; then
    run_delta_preset th8-512k 8388608 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,th8-1m,* ]]; then
    run_delta_preset th8-1m 8388608 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,th4-512k,* ]]; then
    run_delta_preset th4-512k 4194304 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,th4-1m,* ]]; then
    run_delta_preset th4-1m 4194304 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,th1-512k,* ]]; then
    run_delta_preset th1-512k 1048576 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,th1-1m,* ]]; then
    run_delta_preset th1-1m 1048576 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,th128k-512k,* ]]; then
    run_delta_preset th128k-512k 131072 131072 524288 2097152
  fi
  if [[ ",$PRESETS," == *,th128k-1m,* ]]; then
    run_delta_preset th128k-1m 131072 131072 1048576 4194304
  fi
elif [ "$BENCHMARK_KIND" = "single" ]; then
  if [[ ",$PRESETS," == *,nochunk,* ]]; then
    run_preset nochunk 0 16384 65536 262144
  fi
  if [[ ",$PRESETS," == *,chunk-4m,* ]]; then
    run_preset chunk-4m 4194304 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-8m,* ]]; then
    run_preset chunk-8m 8388608 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-16m,* ]]; then
    run_preset chunk-16m 16777216 262144 1048576 4194304
  fi
  if [[ ",$PRESETS," == *,chunk-32m,* ]]; then
    run_preset chunk-32m 33554432 262144 1048576 4194304
  fi
else
  echo "Unsupported BENCHMARK_KIND=$BENCHMARK_KIND; expected single or delta" >&2
  exit 1
fi

log "Benchmark complete"
log "Summary:"
column -t -s $'\t' "$SUMMARY" | tee -a "$LOG" || cat "$SUMMARY" | tee -a "$LOG"
