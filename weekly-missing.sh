#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

CACHE="${CACHE:-r-packages}"
ATTIC_DB="${ATTIC_DB:-/var/lib/attic/server.db}"
NIX="${NIX:-/nix/var/nix/profiles/default/bin/nix}"
NIX_STORE="${NIX_STORE:-/nix/var/nix/profiles/default/bin/nix-store}"
R_NIXPKGS_DATE="${R_NIXPKGS_DATE:-2026-05-25}"
MAX_JOBS="${MAX_JOBS:-6}"
BUILD_CORES="${BUILD_CORES:-1}"
BATCH_SIZE="${BATCH_SIZE:-5000}"
MAX_BATCHES="${MAX_BATCHES:-0}"
MIN_FREE_GB="${MIN_FREE_GB:-300}"
RUN_GC="${RUN_GC:-auto}"
DRY_RUN="${DRY_RUN:-0}"

LOGDIR="$DIR/logs"
LOG="$LOGDIR/weekly-missing-$(date +%Y-%m-%d_%H%M%S).log"
TMPDIR="$(mktemp -d "$DIR/.weekly-missing.XXXXXX")"
OUTPATHS_JSON="$TMPDIR/outpaths.json"
MISSING_NAMES="$TMPDIR/missing-packages.txt"
BATCH_NAMES="$TMPDIR/batch-packages.txt"
MISSING_NIX="$TMPDIR/missing-packages.nix"
RESULTS_JSON="$TMPDIR/results.json"
BUILT_PATHS="$TMPDIR/built-paths.txt"

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

free_gb() {
  df -BG / | awk 'NR == 2 { sub(/G/, "", $4); print $4 }'
}

line_count() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
print(sum(1 for line in path.read_text().splitlines() if line.strip()))
PY
}

select_batch() {
  python3 - "$MISSING_NAMES" "$BATCH_NAMES" "$BATCH_SIZE" <<'PY'
import sys
from pathlib import Path
src, dst, size = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
names = [line for line in src.read_text().splitlines() if line]
if size > 0:
    names = names[:size]
Path(dst).write_text("\n".join(names) + ("\n" if names else ""))
print(len(names))
PY
}

write_batch_nix() {
  cat > "$MISSING_NIX" <<NIX
let
  base = import $DIR/packages.nix;
  names = builtins.filter (name: name != "") (
    builtins.filter builtins.isString (builtins.split "\\n" (builtins.readFile $BATCH_NAMES))
  );
  missingPackages = builtins.listToAttrs (map (name: {
    inherit name;
    value = base.rPackagesSet.\${name};
  }) names);
in
  base // { inherit missingPackages; }
NIX
}

check_missing() {
  echo "[$(date)] Evaluating rPackagesSet output paths..."
  R_NIXPKGS_DATE="$R_NIXPKGS_DATE" "$NIX" eval --impure --json --expr \
    'let x = import ./packages.nix; in builtins.mapAttrs (name: value: value.outPath) x.rPackagesSet' \
    > "$OUTPATHS_JSON"

  echo "[$(date)] Checking Attic SQLite database..."
  python3 "$DIR/weekly-sqlite.py" "$OUTPATHS_JSON" "$MISSING_NAMES" "$ATTIC_DB" "$CACHE"
}

maybe_gc() {
  free="$(free_gb)"
  if [ "$RUN_GC" = "1" ]; then
    echo "[$(date)] Running nix-store --gc; RUN_GC=1 and / has ${free} GiB free."
    "$NIX_STORE" --gc || true
  elif [ "$RUN_GC" = "auto" ] && [ "$free" -lt "$MIN_FREE_GB" ]; then
    echo "[$(date)] Running nix-store --gc; / has ${free} GiB free, below MIN_FREE_GB=$MIN_FREE_GB."
    "$NIX_STORE" --gc || true
  else
    echo "[$(date)] Skipping nix-store --gc; / has ${free} GiB free."
  fi
}

build_batch() {
  batch_count="$1"
  write_batch_nix
  rm -f "$RESULTS_JSON" "$BUILT_PATHS"

  echo "[$(date)] Building $batch_count packages..."
  set +e
  R_NIXPKGS_DATE="$R_NIXPKGS_DATE" "$NIX" run .#nix-fast-build -- \
    --file "$MISSING_NIX" \
    -A missingPackages \
    --max-jobs "$MAX_JOBS" \
    --option cores "$BUILD_CORES" \
    --result-file "$RESULTS_JSON" \
    --no-link \
    --skip-cached \
    --attic-cache "$CACHE" \
    --no-nom
  status="$?"
  set -e

  if [ "$status" -ne 0 ]; then
    echo "[$(date)] nix-fast-build exited with status $status; summarizing anyway."
  fi

  python3 "$DIR/update-blacklist.py" "$RESULTS_JSON" "$DIR/blacklist.txt" "$BUILT_PATHS"
  python3 "$DIR/summarize-results.py" "$RESULTS_JSON"
}

echo "[$(date)] Weekly missing-package run"
echo "R_NIXPKGS_DATE=$R_NIXPKGS_DATE CACHE=$CACHE ATTIC_DB=$ATTIC_DB"
echo "MAX_JOBS=$MAX_JOBS BUILD_CORES=$BUILD_CORES DRY_RUN=$DRY_RUN"
echo "BATCH_SIZE=$BATCH_SIZE MAX_BATCHES=$MAX_BATCHES RUN_GC=$RUN_GC MIN_FREE_GB=$MIN_FREE_GB"
echo "free disk at start: $(free_gb) GiB"

batch=1
while true; do
  check_missing
  missing_count="$(line_count "$MISSING_NAMES")"

  if [ "$missing_count" -eq 0 ]; then
    echo "[$(date)] Nothing to build."
    break
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "[$(date)] Dry run; not building $missing_count missing packages."
    break
  fi

  if [ "$MAX_BATCHES" -gt 0 ] && [ "$batch" -gt "$MAX_BATCHES" ]; then
    echo "[$(date)] Reached MAX_BATCHES=$MAX_BATCHES with $missing_count packages still missing."
    break
  fi

  batch_count="$(select_batch)"
  echo "[$(date)] Batch $batch: missing before batch=$missing_count, building=$batch_count, free disk=$(free_gb) GiB."
  build_batch "$batch_count"
  maybe_gc
  batch=$((batch + 1))
done

echo "[$(date)] Writing report for $R_NIXPKGS_DATE..."
python3 "$DIR/report-date.py" "$R_NIXPKGS_DATE" --blacklist "$DIR/blacklist.txt" --cache "$CACHE" --attic-db "$ATTIC_DB" --nix "$NIX"

echo "[$(date)] Done."
