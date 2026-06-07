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
exec > >(tee -a "$LOG") 2>&1

## ── 1. Build individual packages with nix-fast-build & update blacklist ──────
echo "[$(date)] Regenerating bioc_list.nix..."
Rscript "$DIR/gen_packages.R"

echo "[$(date)] Running nix-fast-build to build all individual packages..."
nix run .#nix-fast-build -- \
  --file "$EXPR" \
  -A rPackagesSet \
  --result-file "$DIR/results.json" \
  --no-link \
  --skip-cached

echo "[$(date)] Updating blacklist..."
python3 "$DIR/update-blacklist.py" "$DIR/results.json" "$DIR/blacklist.txt"

echo "[$(date)] Re-regenerating bioc_list.nix with updated blacklist..."
Rscript "$DIR/gen_packages.R"

# ── 2. Final build of rEnv (should be perfectly clean now) ───────────────────
echo "[$(date)] Starting final build of rEnv..."
nix-build "$EXPR" -A rEnv -o "$RESULT"

# ── 3. Collect paths ──────────────────────────────────────────────────────────
echo "[$(date)] Collecting store paths (runtime closure)..."
PATHS=$(nix-store -qR "$RESULT")
echo "$PATHS" | sort > "$LOGDIR/cached-paths-$(date +%Y-%m-%d_%H%M%S).txt"

# ── 4. Sign & push ────────────────────────────────────────────────────────────
echo "[$(date)] Signing store paths..."
nix store sign --key-file "$KEY" $PATHS

echo "[$(date)] Pushing to Attic (NFS)..."
$ATTIC push "$CACHE" $PATHS --jobs 1

# ── 5. Clean up ───────────────────────────────────────────────────────────────
rm -f "$RESULT"
echo "[$(date)] Done."
