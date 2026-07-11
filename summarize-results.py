#!/usr/bin/env python3
import json
import os
import subprocess
import sys

from attic_db import backend, query, sql_string, sqlite_path


def clean_attr(attr):
    if not attr:
        return None
    if attr.startswith('"') and attr.endswith('"'):
        return attr[1:-1]
    return attr


def format_bytes(value):
    value = float(value or 0)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.2f} {unit}"
        value /= 1024


def read_attic_growth(started_at, database):
    if not started_at or not database:
        return None
    if backend(database) == "sqlite" and not os.path.exists(sqlite_path(database)):
        return None

    timestamp = sql_string(started_at)
    nar_count, nar_logical = query(
        database,
        f"""
            select count(*), coalesce(sum(nar_size), 0)
            from nar
            where created_at >= {timestamp}
        """,
        tabs=True,
    ).strip().split("\t")
    chunk_count, stored_bytes, chunk_logical = query(
        database,
        f"""
            select count(*), coalesce(sum(file_size), 0), coalesce(sum(chunk_size), 0)
            from chunk
            where created_at >= {timestamp}
        """,
        tabs=True,
    ).strip().split("\t")

    return {
        "nar_count": int(nar_count),
        "nar_logical": int(nar_logical),
        "chunk_count": int(chunk_count),
        "stored_bytes": int(stored_bytes),
        "chunk_logical": int(chunk_logical),
    }


def main():
    if len(sys.argv) not in (2, 4):
        print("Usage: summarize-results.py <results.json> [run-started-at database]")
        sys.exit(1)

    results_path = sys.argv[1]
    started_at = sys.argv[2] if len(sys.argv) == 4 else None
    attic_db = sys.argv[3] if len(sys.argv) == 4 else None
    if not os.path.exists(results_path):
        print(f"Error: Results file {results_path} not found.")
        sys.exit(1)

    with open(results_path, "r") as f:
        data = json.load(f)

    build_successes = set()
    build_failures = set()
    upload_successes = set()
    upload_failures = set()
    other_failures = set()

    for r in data.get("results", []):
        attr = clean_attr(r.get("attr"))
        if not attr:
            continue

        result_type = r.get("type")
        success = r.get("success", False)

        if result_type == "BUILD":
            if success:
                build_successes.add(attr)
            else:
                build_failures.add(attr)
        elif result_type == "ATTIC":
            if success:
                upload_successes.add(attr)
            else:
                upload_failures.add(attr)
        elif not success:
            other_failures.add(attr)

    print("nix-fast-build summary:")
    print(f"  build successes: {len(build_successes)}")
    print(f"  build failures: {len(build_failures)}")
    print(f"  Attic successful upload checks: {len(upload_successes)}")
    print(f"  Attic upload failures: {len(upload_failures)}")

    try:
        growth = read_attic_growth(started_at, attic_db)
    except (subprocess.CalledProcessError, ValueError) as e:
        growth = None
        print(f"  Attic newly uploaded paths: unavailable ({e})")

    if growth is not None:
        print(f"  Attic newly uploaded paths: {growth['nar_count']}")
        print(
            f"  Attic newly uploaded logical size: {format_bytes(growth['nar_logical'])}"
        )
        print(f"  Attic newly stored chunks: {growth['chunk_count']}")
        print(f"  Attic newly stored size: {format_bytes(growth['stored_bytes'])}")
    if other_failures:
        print(f"  other failures: {len(other_failures)}")

    if build_failures:
        print("  failed builds:")
        for attr in sorted(build_failures):
            print(f"    - {attr}")

    if upload_failures:
        print("  failed Attic uploads:")
        for attr in sorted(upload_failures):
            print(f"    - {attr}")


if __name__ == "__main__":
    main()
