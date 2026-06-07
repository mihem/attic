#!/usr/bin/env bash
set -euo pipefail

ATTIC=/etc/attic/attic-client-bin/bin/attic
CACHE="r-packages"
DIR="/home/ubuntu/attic"
EXPR="$DIR/packages.nix"
KEY="/etc/attic/signing-key.sec"
RESULT="$DIR/result"
LOGDIR="$DIR/logs"
LOG="$LOGDIR/build-$(date +%Y-%m-%d_%H%M%S).log"

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

## ── 1. Fix blacklist (detect & blacklist any build failures) ──────────────────
echo "[$(date)] Checking for build failures and updating blacklist..."
bash "$DIR/fix-blacklist.sh"

# ── 2. Final build (should be clean after fix-blacklist.sh) ──────────────────
echo "[$(date)] Starting final build..."
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
