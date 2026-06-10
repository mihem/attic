#!/usr/bin/env python3
import json
import os
import sys


def clean_attr(attr):
    if not attr:
        return None
    if attr.startswith('"') and attr.endswith('"'):
        return attr[1:-1]
    return attr


def main():
    if len(sys.argv) != 2:
        print("Usage: summarize-results.py <results.json>")
        sys.exit(1)

    results_path = sys.argv[1]
    if not os.path.exists(results_path):
        print(f"Error: Results file {results_path} not found.")
        sys.exit(1)

    with open(results_path, 'r') as f:
        data = json.load(f)

    build_successes = set()
    build_failures = set()
    upload_successes = set()
    upload_failures = set()
    other_failures = set()

    for r in data.get('results', []):
        attr = clean_attr(r.get('attr'))
        if not attr:
            continue

        result_type = r.get('type')
        success = r.get('success', False)

        if result_type == 'BUILD':
            if success:
                build_successes.add(attr)
            else:
                build_failures.add(attr)
        elif result_type == 'ATTIC':
            if success:
                upload_successes.add(attr)
            else:
                upload_failures.add(attr)
        elif not success:
            other_failures.add(attr)

    print("nix-fast-build summary:")
    print(f"  build successes: {len(build_successes)}")
    print(f"  build failures: {len(build_failures)}")
    print(f"  Attic uploads pushed: {len(upload_successes)}")
    print(f"  Attic upload failures: {len(upload_failures)}")
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


if __name__ == '__main__':
    main()
