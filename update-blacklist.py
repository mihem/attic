#!/usr/bin/env python3
import json
import os
import sys

def main():
    if len(sys.argv) < 3:
        print("Usage: update-blacklist.py <results.json> <blacklist.txt> [built_paths_output.txt]")
        sys.exit(1)

    results_path = sys.argv[1]
    blacklist_path = sys.argv[2]
    built_paths_out_path = sys.argv[3] if len(sys.argv) > 3 else None

    if not os.path.exists(results_path):
        print(f"Error: Results file {results_path} not found.")
        sys.exit(1)

    with open(results_path, 'r') as f:
        data = json.load(f)

    failed_packages = set()
    ignored_upload_failures = set()
    success_paths = []

    for r in data.get('results', []):
        if not r.get('success', False):
            attr = r.get('attr')
            if attr:
                # Strip escaped quotes (e.g. '"Organism.dplyr"' -> 'Organism.dplyr')
                if attr.startswith('"') and attr.endswith('"'):
                    attr = attr[1:-1]
                if r.get('type') == 'ATTIC':
                    ignored_upload_failures.add(attr)
                else:
                    failed_packages.add(attr)
        else:
            if r.get('type') == 'BUILD':
                outputs = r.get('outputs', {})
                for out_path in outputs.values():
                    if out_path and os.path.exists(out_path):
                        success_paths.append(out_path)

    if ignored_upload_failures:
        print(
            f"Ignoring {len(ignored_upload_failures)} Attic upload failures "
            "for blacklist purposes:"
        )
        for pkg in sorted(ignored_upload_failures):
            print(f"  -> upload failed, not blacklisted: {pkg}")

    # 1. Update Blacklist
    if failed_packages:
        existing_blacklist = set()
        if os.path.exists(blacklist_path):
            with open(blacklist_path, 'r') as f:
                existing_blacklist = {line.strip() for line in f if line.strip()}

        new_failures = sorted(list(failed_packages - existing_blacklist))

        if new_failures:
            print(f"Adding {len(new_failures)} newly failed packages to blacklist:")
            with open(blacklist_path, 'a') as f:
                for pkg in new_failures:
                    print(f"  -> blacklisted: {pkg}")
                    f.write(f"{pkg}\n")
        else:
            print("All detected failures are already blacklisted.")
    else:
        print("No build failures detected.")

    # 2. Output successfully built, locally-present store paths
    if built_paths_out_path:
        unique_success_paths = sorted(list(set(success_paths)))
        with open(built_paths_out_path, 'w') as f:
            for path in unique_success_paths:
                f.write(f"{path}\n")
        print(f"Identified {len(unique_success_paths)} active local store paths to verify.")

if __name__ == '__main__':
    main()
