#!/usr/bin/env python3
import os
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from attic_db import query  # noqa: E402


def main():
    random.seed(20260609)
    bioc_list = Path.home() / "attic" / "bioc_list.nix"
    names = re.findall(r'"([^"]+)"', bioc_list.read_text())
    name_by_norm = {name.lower().replace("_", "."): name for name in names}

    sql = """
select store_path,nar_size
from object join nar on nar.id=object.nar_id
where store_path like '%-r-%';
"""
    database = os.environ.get(
        "ATTIC_DATABASE", "postgresql:///attic?host=/var/run/postgresql"
    )
    rows = query(database, sql, tabs=True)

    candidates = {}
    for line in rows.splitlines():
        parts = line.rsplit("\t", 1)
        if len(parts) != 2:
            continue
        path, size = parts
        match = re.search(r"-r-(.+)-([0-9][^-]*)\Z", path)
        if not match:
            continue
        pkg_norm = match.group(1).lower()
        if pkg_norm not in name_by_norm:
            continue
        name = name_by_norm[pkg_norm]
        attr = name.replace(".", "_").replace("-", "_")
        candidates[attr] = max(candidates.get(attr, 0), int(size))

    buckets = [
        ("0-8", 0, 8 * 1024 * 1024),
        ("8-16", 8 * 1024 * 1024, 16 * 1024 * 1024),
        ("16-32", 16 * 1024 * 1024, 32 * 1024 * 1024),
        ("gt32", 32 * 1024 * 1024, sys.maxsize),
    ]

    for label, lo, hi in buckets:
        attrs = [(attr, size) for attr, size in candidates.items() if lo <= size < hi]
        random.shuffle(attrs)
        for attr, size in attrs:
            print(f"{label}\t{attr}\t{size // 1024 // 1024}")


if __name__ == "__main__":
    main()
