#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

from attic_db import cached_hashes, upstream_cached_paths


def store_hash(out_path):
    return out_path.split("/nix/store/", 1)[1].split("-", 1)[0]


def main():
    parser = argparse.ArgumentParser(description="Classify evaluated cache outputs.")
    parser.add_argument("outpaths_json")
    parser.add_argument("missing_names")
    parser.add_argument("database")
    parser.add_argument("cache_name")
    parser.add_argument("--upstream-paths-file", required=True)
    parser.add_argument("--upstream-store", default="https://cache.nixos.org")
    parser.add_argument("--narinfo-workers", type=int, default=16)
    args = parser.parse_args()

    with open(args.outpaths_json) as handle:
        outpaths = json.load(handle)

    cached = cached_hashes(args.database, args.cache_name)
    upstream_file = Path(args.upstream_paths_file)
    if upstream_file.exists():
        upstream = set(upstream_file.read_text().splitlines())
    else:
        not_in_attic = [
            path for path in outpaths.values() if store_hash(path) not in cached
        ]
        upstream, file_bytes, nar_bytes = upstream_cached_paths(
            not_in_attic,
            args.upstream_store,
            workers=args.narinfo_workers,
        )
        upstream_file.write_text(
            "\n".join(sorted(upstream)) + ("\n" if upstream else "")
        )
        print(f"upstream compressed size: {file_bytes / 1024**3:.2f} GiB")
        print(f"upstream unpacked size: {nar_bytes / 1024**3:.2f} GiB")
    missing = [
        name
        for name, path in sorted(outpaths.items())
        if store_hash(path) not in cached and path not in upstream
    ]

    with open(args.missing_names, "w") as handle:
        for name in missing:
            handle.write(name + "\n")

    print(f"total attrs: {len(outpaths)}")
    available_count = len(outpaths) - len(missing)
    print(f"available in Attic or in cache.nixos.org: {available_count}")
    print(f"missing from Attic and cache.nixos.org: {len(missing)}")
    if outpaths and available_count == 0:
        print(
            "warning: no evaluated store paths are present in Attic or in cache.nixos.org; changing R_NIXPKGS_DATE can change every output hash"
        )
    if missing:
        print("missing sample: " + ", ".join(missing[:50]))


if __name__ == "__main__":
    main()
