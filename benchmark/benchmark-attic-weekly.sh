#!/usr/bin/env bash
set -euo pipefail

# Benchmark real weekly-revision cache growth. This builds the same sampled R
# packages from two rstats-on-nix/nixpkgs date revisions, then pushes old and
# new outputs into temporary Attic caches using selected chunking settings.

ATTIC=${ATTIC:-/etc/attic/attic-client-bin/bin/attic}
CONFIG=${CONFIG:-/etc/attic/server.toml}
SERVICE=${SERVICE:-attic-server.service}
KEY=${KEY:-/etc/attic/signing-key.sec}
LOGDIR=${LOGDIR:-./logs}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OLD_REV=${OLD_REV:-2026-05-18}
NEW_REV=${NEW_REV:-2026-05-25}
PATH_COUNT=${PATH_COUNT:-6}
REAL_MIN_MIB=${REAL_MIN_MIB:-1}
REAL_MAX_MIB=${REAL_MAX_MIB:-20}
MAX_CANDIDATES=${MAX_CANDIDATES:-30}
JOBS=${JOBS:-8}
PUSH_CLOSURE=${PUSH_CLOSURE:-0}
BUILD_TIMEOUT=${BUILD_TIMEOUT:-120}
EXACT_ATTRS=${EXACT_ATTRS:-}
ALLOW_LOCAL_BUILDS=${ALLOW_LOCAL_BUILDS:-0}
KEEP_CACHES=${KEEP_CACHES:-0}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}

if ! command -v nix-build >/dev/null 2>&1 && [ -r /etc/profile.d/nix.sh ]; then
	. /etc/profile.d/nix.sh
fi

if ! command -v nix-build >/dev/null 2>&1 && [ -x /nix/var/nix/profiles/default/bin/nix-build ]; then
	export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

mkdir -p "$LOGDIR"
LOG="$LOGDIR/attic-weekly-benchmark-$RUN_ID.log"
SUMMARY="$LOGDIR/attic-weekly-benchmark-$RUN_ID.tsv"
TMPDIR=$(mktemp -d)
BACKUP="$TMPDIR/server.toml.orig"
OLD_EXPR="$TMPDIR/old.nix"
NEW_EXPR="$TMPDIR/new.nix"
SELECTED="$TMPDIR/selected.tsv"
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
			"$ATTIC" cache destroy "$cache" --no-confirm >>"$LOG" 2>&1 || true
		done <"$CACHES_CREATED"
	fi
	if [ -d "$TMPDIR" ]; then
		chmod -R u+w "$TMPDIR" 2>/dev/null || true
	fi
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

usage() {
	cat <<EOF
Usage: $0

Environment overrides:
  OLD_REV=2026-05-18      Old rstats-on-nix/nixpkgs archive date/rev
  NEW_REV=2026-05-25      New rstats-on-nix/nixpkgs archive date/rev
  PATH_COUNT=6            Number of packages that must build in both revs
  REAL_MIN_MIB=1          Sample from cached packages at least this large
  REAL_MAX_MIB=20         Sample from cached packages at most this large
  MAX_CANDIDATES=30       Maximum candidates to try before giving up
  JOBS=8                  attic push --jobs value
  PUSH_CLOSURE=0           Set to 1 to push closures instead of package outputs only
  BUILD_TIMEOUT=120        Seconds per substitute-only realization attempt
  EXACT_ATTRS=             Comma-separated exact pkgs.rPackages attrs to test
  ALLOW_LOCAL_BUILDS=0     Set to 1 to allow local builds for EXACT_ATTRS
  KEEP_CACHES=0           Set to 1 to keep temporary benchmark caches

The script creates temporary caches only. It does not touch r-packages.
By default it copies old/new package outputs into fresh store paths and pushes
only those fresh paths with --no-closure. Set PUSH_CLOSURE=1 if you want the
fresh copied paths' detected references/closures included too.
By default, package selection disables local builds with max-jobs=0 and
fallback=false. With EXACT_ATTRS and ALLOW_LOCAL_BUILDS=1, only those exact
attrs are allowed to build locally.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	usage
	exit 0
fi

for cmd in nix-build sqlite3 sudo python3 timeout; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Required command not found: $cmd" >&2
		exit 1
	fi
done

if [ ! -x "$ATTIC" ]; then
	echo "Attic client not executable: $ATTIC" >&2
	exit 1
fi

sudo test -r "$CONFIG"
sudo cp "$CONFIG" "$BACKUP"

cat >"$SUMMARY" <<'EOF'
preset	cache	packages	old_rev	new_rev	old_seconds	old_chunks	old_chunk_mib	new_seconds	new_chunks	new_chunk_mib	status
EOF

log() {
	echo "[$(date)] $*" | tee -a "$LOG"
}

db_scalar() {
	sudo sqlite3 /var/lib/attic/server.db "$1"
}

db_stats() {
	db_scalar "select (select count(*) from chunk) || ' ' || coalesce((select sum(chunk_size) from chunk), 0);"
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

write_expr() {
	local rev=$1
	local out=$2
	local names_file=$3
	local names_nix="$TMPDIR/names-$(basename "$out").nix"

	python3 - "$names_file" "$names_nix" <<'PY'
import sys
names = []
with open(sys.argv[1]) as f:
    for line in f:
        name = line.strip().split('\t')[0]
        if name and name not in names:
            names.append(name)
with open(sys.argv[2], 'w') as f:
    f.write('[\n')
    for name in names:
        f.write(f'  "{name}"\n')
    f.write(']\n')
PY

	cat >"$out" <<EOF
let
  pkgs = import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/${rev}.tar.gz") {
    config = { allowBroken = true; };
  };
  names = import ${names_nix};
  existing = builtins.filter (name: builtins.hasAttr name pkgs.rPackages) names;
in {
  selected = builtins.listToAttrs (builtins.map (name: {
    inherit name;
    value = builtins.getAttr name pkgs.rPackages;
  }) existing);
}
EOF
}

attr_for_store_path() {
	python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1].split('/')[-1]
name = re.sub(r'^[^-]+-r-', '', path)
name = re.sub(r'-[0-9][A-Za-z0-9.+_~:-]*$', '', name)
print(name.replace('.', '_'))
PY
}

select_and_build_packages() {
	local candidates="$TMPDIR/candidates.tsv"
	local candidate_attrs="$TMPDIR/candidate-attrs.tsv"
	local selected=0 tried=0 attr mib old_out new_out old_path new_path

	if [ -n "$EXACT_ATTRS" ]; then
		python3 - "$EXACT_ATTRS" "$candidate_attrs" <<'PY'
import sys

attrs = [x.strip() for x in sys.argv[1].split(',') if x.strip()]
with open(sys.argv[2], 'w') as out:
    for attr in attrs:
        out.write(f'{attr}\t0\n')
PY
		PATH_COUNT=$(wc -l <"$candidate_attrs")
	else
		sudo sqlite3 -tabs /var/lib/attic/server.db \
			"select store_path, cast(round(nar_size/1024.0/1024) as integer) from object join nar on nar.id=object.nar_id where store_path like '%-r-%' and nar_size between $((REAL_MIN_MIB * 1024 * 1024)) and $((REAL_MAX_MIB * 1024 * 1024)) order by nar_size desc limit $MAX_CANDIDATES;" \
			>"$candidates"

		python3 - "$candidates" "$candidate_attrs" <<'PY'
import re
import sys

seen = set()
with open(sys.argv[1]) as f, open(sys.argv[2], 'w') as out:
    for line in f:
        store_path, mib = line.rstrip('\n').split('\t')
        base = store_path.split('/')[-1]
        name = re.sub(r'^[^-]+-r-', '', base)
        name = re.sub(r'-[0-9][A-Za-z0-9.+_~:-]*$', '', name)
        attr = name.replace('.', '_')
        if attr not in seen:
            seen.add(attr)
            out.write(f'{attr}\t{mib}\n')
PY
	fi

	write_expr "$OLD_REV" "$OLD_EXPR" "$candidate_attrs"
	write_expr "$NEW_REV" "$NEW_EXPR" "$candidate_attrs"

	: >"$SELECTED"
	while IFS=$'\t' read -r attr mib; do
		tried=$((tried + 1))
		old_out="$TMPDIR/old-$attr.out"
		new_out="$TMPDIR/new-$attr.out"
		log "Trying substitute-only $attr ($mib MiB candidate)"

		if [ "$ALLOW_LOCAL_BUILDS" = "1" ]; then
			old_cmd=(timeout "$BUILD_TIMEOUT" nix-build "$OLD_EXPR" -A "selected.$attr" --no-out-link)
			new_cmd=(timeout "$BUILD_TIMEOUT" nix-build "$NEW_EXPR" -A "selected.$attr" --no-out-link)
		else
			old_cmd=(timeout "$BUILD_TIMEOUT" nix-build "$OLD_EXPR" -A "selected.$attr" --no-out-link --option max-jobs 0 --option fallback false)
			new_cmd=(timeout "$BUILD_TIMEOUT" nix-build "$NEW_EXPR" -A "selected.$attr" --no-out-link --option max-jobs 0 --option fallback false)
		fi

		if ! "${old_cmd[@]}" >"$old_out" 2>>"$LOG"; then
			log "Skipping $attr; old revision unavailable without local build or timed out"
			continue
		fi

		if ! "${new_cmd[@]}" >"$new_out" 2>>"$LOG"; then
			log "Skipping $attr; new revision unavailable without local build or timed out"
			continue
		fi

		old_path=""
		while IFS= read -r line; do old_path=$line; done <"$old_out"
		new_path=""
		while IFS= read -r line; do new_path=$line; done <"$new_out"
		if [ -e "$old_path" ] && [ -e "$new_path" ]; then
			printf '%s\t%s\t%s\t%s\n' "$attr" "$old_path" "$new_path" "$mib" >>"$SELECTED"
			selected=$((selected + 1))
			log "Selected $attr: old=$old_path new=$new_path"
			if [ "$selected" -ge "$PATH_COUNT" ]; then
				break
			fi
		fi
	done <"$candidate_attrs"

	if [ "$selected" -lt "$PATH_COUNT" ]; then
		echo "Only selected $selected packages after trying $tried candidates; increase MAX_CANDIDATES, lower PATH_COUNT, or run builds manually" >&2
		exit 1
	fi

	log "Selected $selected packages for weekly benchmark"
	tee -a "$LOG" <"$SELECTED" >/dev/null
}

paths_file() {
	local column=$1
	local preset=$2
	local label=$3
	local file=$4
	local attr old_path new_path mib src dir store_path i=0

	: >"$file"
	while IFS=$'\t' read -r attr old_path new_path mib; do
		i=$((i + 1))
		if [ "$column" = "2" ]; then
			src=$old_path
		else
			src=$new_path
		fi
		dir="$TMPDIR/fresh-$preset-$label-$i"
		mkdir -p "$dir"
		cp -a "$src" "$dir/payload"
		chmod -R u+w "$dir" 2>/dev/null || true
		printf 'preset=%s\nlabel=%s\nattr=%s\nsource=%s\nold_rev=%s\nnew_rev=%s\nrun_id=%s\n' \
			"$preset" "$label" "$attr" "$src" "$OLD_REV" "$NEW_REV" "$RUN_ID" >"$dir/benchmark-metadata.txt"
		store_path=$(nix-store --add "$dir")
		echo "$store_path" >>"$file"
		chmod -R u+w "$dir" 2>/dev/null || true
		rm -rf "$dir"
	done <"$SELECTED"
}

sign_paths() {
	local file=$1
	if [ -f "$KEY" ]; then
		xargs -r nix store sign --key-file "$KEY" <"$file"
	fi
}

attic_push_paths() {
	local cache=$1
	local file=$2

	if [ "$PUSH_CLOSURE" = "1" ]; then
		"$ATTIC" push "$cache" $(cat "$file") --jobs "$JOBS" >>"$LOG" 2>&1
	else
		"$ATTIC" push "$cache" --no-closure $(cat "$file") --jobs "$JOBS" >>"$LOG" 2>&1
	fi
}

run_preset() {
	local preset=$1 threshold=$2 min_size=$3 avg_size=$4 max_size=$5
	local cache="bench-weekly-$preset-$RUN_ID"
	local old_paths="$TMPDIR/old-paths-$preset.txt"
	local new_paths="$TMPDIR/new-paths-$preset.txt"
	local before after_old after_new before_chunks before_bytes old_chunks old_bytes new_chunks new_bytes
	local start end old_seconds new_seconds status=ok

	log "Applying preset $preset: threshold=$threshold min=$min_size avg=$avg_size max=$max_size"
	apply_chunking "$threshold" "$min_size" "$avg_size" "$max_size"
	sudo systemctl restart "$SERVICE"
	sleep 2
	sudo systemctl is-active --quiet "$SERVICE"

	log "Creating fresh old/new store paths for $preset"
	paths_file 2 "$preset" old "$old_paths"
	paths_file 3 "$preset" new "$new_paths"

	log "Signing paths for $preset"
	sign_paths "$old_paths"
	sign_paths "$new_paths"

	log "Creating temporary cache $cache"
	"$ATTIC" cache create "$cache" >>"$LOG" 2>&1
	echo "$cache" >>"$CACHES_CREATED"

	before=$(db_stats)
	read -r before_chunks before_bytes <<<"$before"

	log "Pushing old revision $OLD_REV to $cache"
	start=$(date +%s)
	if ! attic_push_paths "$cache" "$old_paths"; then
		status=failed-old
	fi
	end=$(date +%s)
	old_seconds=$((end - start))

	after_old=$(db_stats)
	read -r old_chunks old_bytes <<<"$after_old"

	log "Pushing new revision $NEW_REV to $cache"
	start=$(date +%s)
	if [ "$status" = "ok" ] && ! attic_push_paths "$cache" "$new_paths"; then
		status=failed-new
	fi
	end=$(date +%s)
	new_seconds=$((end - start))

	after_new=$(db_stats)
	read -r new_chunks new_bytes <<<"$after_new"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$preset" \
		"$cache" \
		"$PATH_COUNT" \
		"$OLD_REV" \
		"$NEW_REV" \
		"$old_seconds" \
		"$((old_chunks - before_chunks))" \
		"$(((old_bytes - before_bytes) / 1024 / 1024))" \
		"$new_seconds" \
		"$((new_chunks - old_chunks))" \
		"$(((new_bytes - old_bytes) / 1024 / 1024))" \
		"$status" | tee -a "$SUMMARY"

	if [ "$KEEP_CACHES" = "1" ]; then
		log "Keeping temporary cache $cache because KEEP_CACHES=1"
	fi
}

log "Starting weekly Attic benchmark run $RUN_ID"
log "Detailed log: $LOG"
log "Summary TSV: $SUMMARY"
log "Sample: OLD_REV=$OLD_REV NEW_REV=$NEW_REV PATH_COUNT=$PATH_COUNT REAL_MIN_MIB=$REAL_MIN_MIB REAL_MAX_MIB=$REAL_MAX_MIB MAX_CANDIDATES=$MAX_CANDIDATES JOBS=$JOBS PUSH_CLOSURE=$PUSH_CLOSURE BUILD_TIMEOUT=$BUILD_TIMEOUT"

select_and_build_packages

run_preset nochunk 0 16384 65536 262144
run_preset chunk-8m 8388608 262144 1048576 4194304
run_preset chunk-16m 16777216 262144 1048576 4194304
run_preset chunk-32m 33554432 262144 1048576 4194304

log "Benchmark complete"
log "Summary:"
column -t -s $'\t' "$SUMMARY" | tee -a "$LOG" || cat "$SUMMARY" | tee -a "$LOG"
