#!/usr/bin/env bash
# fix-blacklist.sh
# Iteratively builds packages.nix -A rEnv, detects root-cause build failures,
# and adds the responsible packages to blacklist.txt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_NIX="$DIR/packages.nix"
BLACKLIST="$DIR/blacklist.txt"
BIOC_LIST="$DIR/bioc_list.nix"

add_to_blacklist() {
  local pkg="$1"
  if grep -qFx "$pkg" "$BLACKLIST" 2>/dev/null; then
    return 1
  fi
  echo "$pkg" >> "$BLACKLIST"
  echo "  -> blacklisted: $pkg"
  return 0
}

drv_to_rname() {
  basename "$1" | sed 's/^[^-]*-r-//; s/-[0-9].*//'
}

drv_is_in_our_list() {
  local drv="$1"
  local rname nix_name
  rname=$(drv_to_rname "$drv")
  nix_name="${rname//./_}"
  grep -qF "\"${nix_name}\"" "$BIOC_LIST"
}

find_our_dependent() {
  local fail_drv="$1"
  local -a visited=()
  local -a queue=("$fail_drv")
  while [ ${#queue[@]} -gt 0 ]; do
    local current="${queue[0]}"
    queue=("${queue[@]:1}")
    local already=0
    for v in "${visited[@]:-}"; do [[ "$v" == "$current" ]] && already=1 && break; done
    [[ $already -eq 1 ]] && continue
    visited+=("$current")
    if [[ "$current" != "$fail_drv" ]] && drv_is_in_our_list "$current"; then
      drv_to_rname "$current"
      return 0
    fi
    local refs
    refs=$(nix-store -q --referrers "$current" 2>/dev/null \
      | grep '\.drv$' \
      | grep -v "nix-shell" \
      || true)
    for r in $refs; do
      queue+=("$r")
    done
  done
  return 1
}

MAX_ITER=40
for i in $(seq 1 $MAX_ITER); do
  echo "[fix-blacklist] Iteration $i: regenerating bioc_list.nix..."
  cd "$DIR"
  Rscript gen_packages.R 2>&1 | grep -v "^$"
  echo "[fix-blacklist] Building..."
  BUILD_OUT=$(nix-build "$PACKAGES_NIX" -A rEnv --no-out-link 2>&1 || true)
  FAIL_DRVS=$(echo "$BUILD_OUT" \
    | grep "Cannot build" \
    | grep -v "dependency failed" \
    | grep -oP "/nix/store/\S+\.drv" \
    | grep -v "nix-shell" \
    || true)
  if [ -z "$FAIL_DRVS" ]; then
    echo "[fix-blacklist] Build clean after $i iteration(s)."
    exit 0
  fi
  made_progress=0
  for fail_drv in $FAIL_DRVS; do
    fail_rname=$(drv_to_rname "$fail_drv")
    echo "[fix-blacklist] Root failure: $fail_rname"
    if drv_is_in_our_list "$fail_drv"; then
      if add_to_blacklist "$fail_rname"; then
        made_progress=1
      fi
    else
      echo "[fix-blacklist]   '$fail_rname' is a transitive dep, walking referrer graph..."
      dependent=$(find_our_dependent "$fail_drv" || true)
      if [ -n "$dependent" ]; then
        if add_to_blacklist "$dependent"; then
          made_progress=1
        fi
      else
        echo "[fix-blacklist]   WARNING: no dependent found — blacklisting $fail_rname directly"
        if add_to_blacklist "$fail_rname"; then
          made_progress=1
        fi
      fi
    fi
  done
  if [ "$made_progress" -eq 0 ]; then
    echo "[fix-blacklist] ERROR: no progress — manual intervention needed"
    echo "$BUILD_OUT" | tail -20
    exit 1
  fi
done
echo "[fix-blacklist] ERROR: did not converge after $MAX_ITER iterations"
exit 1
