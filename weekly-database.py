#!/usr/bin/env python3
import json
import sys

from attic_db import cached_hashes


def store_hash(out_path):
    return out_path.split("/nix/store/", 1)[1].split("-", 1)[0]


def main():
    if len(sys.argv) != 5:
        print(
            "Usage: weekly-database.py <outpaths.json> <missing-packages.txt> <database> <cache-name>"
        )
        sys.exit(1)

    outpaths_json, missing_names, database, cache_name = sys.argv[1:]

    with open(outpaths_json) as handle:
        outpaths = json.load(handle)

    cached = cached_hashes(database, cache_name)
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
