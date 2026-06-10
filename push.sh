#!/usr/bin/env bash
set -euo pipefail

CACHE="r-packages"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPR="$DIR/packages.nix"
LOGDIR="$DIR/logs"
LOG="$LOGDIR/build-$(date +%Y-%m-%d_%H%M%S).log"
RESULTS_JSON="$DIR/results.json"
BUILT_PATHS_FILE="$DIR/built-paths.txt"

mkdir -p "$LOGDIR"
# Filter out annoying and harmless Nix warnings (e.g. unknown settings) from the output in real-time
exec > >(grep --line-buffered -v "unknown setting" | tee -a "$LOG") 2>&1

## ── 1. Build individual packages with nix-fast-build ──────
echo "[$(date)] Regenerating bioc_list.nix..."
Rscript "$DIR/gen_packages.R"

echo "[$(date)] Running nix-fast-build to build all individual packages..."
nix run .#nix-fast-build -- \
  --file "$EXPR" \
  -A rPackagesSet \
  --result-file "$RESULTS_JSON" \
  --no-link \
  --skip-cached \
  --attic-cache "$CACHE" \
  --no-nom || true

# ── 2. Run update-blacklist and output built paths ───────────────────────────
echo "[$(date)] Updating blacklist and finding active local paths..."
python3 "$DIR/update-blacklist.py" "$RESULTS_JSON" "$DIR/blacklist.txt" "$BUILT_PATHS_FILE"

echo "[$(date)] Re-regenerating bioc_list.nix with updated blacklist..."
Rscript "$DIR/gen_packages.R"

# ── 3. Report successful local paths and upload/build summary ────────────────
if [ -s "$BUILT_PATHS_FILE" ]; then
  echo "[$(date)] nix-fast-build produced these active local paths."
  cp "$BUILT_PATHS_FILE" "$LOGDIR/built-paths-$(date +%Y-%m-%d_%H%M%S).txt"
else
  echo "[$(date)] No active local store paths detected. Attic cache is already up-to-date!"
fi

python3 "$DIR/summarize-results.py" "$RESULTS_JSON"

# ── 4. Clean up ───────────────────────────────────────────────────────────────
rm -f "$BUILT_PATHS_FILE" "$RESULTS_JSON"
echo "[$(date)] Done."
