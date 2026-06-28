#!/usr/bin/env python3
import json
import subprocess
import sys


def store_hash(out_path):
    return out_path.split("/nix/store/", 1)[1].split("-", 1)[0]


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def cached_hashes(attic_db, cache_name):
    query = f"""
      select o.store_path_hash
      from object o
      join cache c on c.id = o.cache_id
      where c.name = {sql_string(cache_name)};
    """
    result = subprocess.run(
        ["sudo", "sqlite3", "-readonly", "-cmd", ".timeout 60000", attic_db, query],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return set(result.stdout.splitlines())


def main():
    if len(sys.argv) != 5:
        print(
            "Usage: weekly-sqlite.py <outpaths.json> <missing-packages.txt> <attic-db> <cache-name>"
        )
        sys.exit(1)

    outpaths_json, missing_names, attic_db, cache_name = sys.argv[1:]

    with open(outpaths_json) as handle:
        outpaths = json.load(handle)

    cached = cached_hashes(attic_db, cache_name)
    missing = [
        name
        for name, path in sorted(outpaths.items())
        if store_hash(path) not in cached
    ]

    with open(missing_names, "w") as handle:
        for name in missing:
            handle.write(name + "\n")

    print(f"total attrs: {len(outpaths)}")
    cached_count = len(outpaths) - len(missing)
    print(f"cached in Attic: {cached_count}")
    print(f"missing from Attic: {len(missing)}")
    if outpaths and cached_count == 0:
        print(
            "warning: no evaluated store paths are present in Attic; changing R_NIXPKGS_DATE can change every output hash"
        )
    if missing:
        print("missing sample: " + ", ".join(missing[:50]))


if __name__ == "__main__":
    main()
