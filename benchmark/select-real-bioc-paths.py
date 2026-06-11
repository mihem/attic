#!/usr/bin/env python3
import os
import random
import re
import subprocess
from pathlib import Path


RUN_SEED = int(os.environ.get("SEED", "20260610"))
PER_BUCKET = int(os.environ.get("PER_BUCKET", "10"))


def attr_name(package_name):
    return package_name.replace(".", "_").replace("-", "_")


def main():
    random.seed(RUN_SEED)
    bioc_list = Path.home() / "attic" / "bioc_list.nix"
    names = re.findall(r'"([^"]+)"', bioc_list.read_text())
    name_by_norm = {name.lower().replace("_", "."): name for name in names}

    query = """
select store_path,nar_size
from object join nar on nar.id=object.nar_id
where store_path like '%-r-%';
"""
    rows = subprocess.check_output(
        ["sudo", "sqlite3", "-tabs", "/var/lib/attic/server.db", query],
        text=True,
    )

    # Keep the largest seen output per attr so duplicate historical variants do
    # not overrepresent a package in the sample.
    by_attr = {}
    for line in rows.splitlines():
        parts = line.rsplit("\t", 1)
        if len(parts) != 2:
            continue
        path, size_text = parts
        if not Path(path).exists():
            continue
        match = re.search(r"-r-(.+)-([0-9][^-]*)\Z", path)
        if not match:
            continue
        pkg_norm = match.group(1).lower()
        if pkg_norm not in name_by_norm:
            continue
        attr = attr_name(name_by_norm[pkg_norm])
        size = int(size_text)
        old = by_attr.get(attr)
        if old is None or size > old[1]:
            by_attr[attr] = (path, size)

    buckets = [
        ("0-4MiB", 0, 4 * 1024 * 1024),
        ("4-8MiB", 4 * 1024 * 1024, 8 * 1024 * 1024),
        ("8-16MiB", 8 * 1024 * 1024, 16 * 1024 * 1024),
        ("16-32MiB", 16 * 1024 * 1024, 32 * 1024 * 1024),
        (">32MiB", 32 * 1024 * 1024, 10**18),
    ]

    selected = []
    for label, lo, hi in buckets:
        candidates = [
            (attr, path, size)
            for attr, (path, size) in by_attr.items()
            if lo <= size < hi
        ]
        random.shuffle(candidates)
        chosen = candidates[:PER_BUCKET]
        if len(chosen) < PER_BUCKET:
            raise SystemExit(
                f"Only found {len(chosen)} paths for bucket {label}; need {PER_BUCKET}"
            )
        selected.extend((label, attr, path, size) for attr, path, size in chosen)

    for label, attr, path, size in selected:
        mib = int(round(size / 1024 / 1024))
        print(f"{path}\t{mib}\t{label}\t{attr}")


if __name__ == "__main__":
    main()
