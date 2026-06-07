#!/usr/bin/env bash
set -euo pipefail

ATTIC=/etc/attic/attic-client-bin/bin/attic
CACHE="r-packages"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPR="$DIR/packages.nix"
KEY="/etc/attic/signing-key.sec"
RESULT="$DIR/result"
LOGDIR="$DIR/logs"
LOG="$LOGDIR/build-$(date +%Y-%m-%d_%H%M%S).log"

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
  --result-file "$DIR/results.json" \
  --no-link \
  --skip-cached

# ── 2. Run update-blacklist and output built paths ───────────────────────────
echo "[$(date)] Updating blacklist and finding active local paths..."
BUILT_PATHS_FILE="$DIR/built-paths.txt"
python3 "$DIR/update-blacklist.py" "$DIR/results.json" "$DIR/blacklist.txt" "$BUILT_PATHS_FILE"

echo "[$(date)] Re-regenerating bioc_list.nix with updated blacklist..."
Rscript "$DIR/gen_packages.R"

# ── 3. Collect & Sign & Push active local paths ──────────────────────────────
if [ -s "$BUILT_PATHS_FILE" ]; then
  echo "[$(date)] Active local store paths detected. Collecting runtime closures..."
  # Read paths from file and pass them to nix-store -qR
  PATHS=$(nix-store -qR $(cat "$BUILT_PATHS_FILE"))
  
  echo "[$(date)] Saving cached paths log..."
  echo "$PATHS" | sort > "$LOGDIR/cached-paths-$(date +%Y-%m-%d_%H%M%S).txt"

  echo "[$(date)] Signing store paths..."
  nix store sign --key-file "$KEY" $PATHS

  echo "[$(date)] Pushing to Attic (NFS)..."
  $ATTIC push "$CACHE" $PATHS --jobs 1
else
  echo "[$(date)] No active local store paths detected. Attic cache is already up-to-date!"
fi

# ── 4. Clean up ───────────────────────────────────────────────────────────────
rm -f "$BUILT_PATHS_FILE" "$DIR/results.json"
echo "[$(date)] Done."
