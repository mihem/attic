#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path


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


def read_blacklist(path):
    names = []
    seen = set()
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and line not in seen:
            names.append(line)
            seen.add(line)
    return names


def nix_eval_outpaths(date, blacklist_file, nix):
    env = os.environ.copy()
    env["R_NIXPKGS_DATE"] = date
    env["BLACKLIST_FILE"] = str(Path(blacklist_file).resolve())
    expr = "let x = import ./packages.nix; in builtins.mapAttrs (name: value: value.outPath) x.rPackagesSet"
    result = subprocess.run(
        [nix, "eval", "--impure", "--json", "--expr", expr],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        env=env,
    )
    return json.loads(result.stdout)


def write_lines(path, lines):
    Path(path).write_text("\n".join(lines) + ("\n" if lines else ""))


def update_index(reports_dir):
    reports_path = Path(reports_dir)
    summaries = []
    for path in sorted(reports_path.glob("*/summary.json")):
        summaries.append(json.loads(path.read_text()))

    lines = [
        "# r-packages Attic cache reports",
        "",
        "| Date | Evaluated | Available | Missing | Blacklisted |",
        "|---|---:|---:|---:|---:|",
    ]
    for item in summaries:
        date = item["date"]
        lines.append(
            f"| [`{date}`]({date}/) | {item['total_evaluated']} | {item['available']} | {item['missing']} | {item['blacklisted']} |"
        )
    lines.extend(
        [
            "",
            "Each date directory contains `available.txt`, `available-store-paths.tsv`, `missing.txt`, `blacklisted.txt`, and `summary.json`.",
        ]
    )
    (reports_path / "README.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Write per-date Attic cache reports.")
    parser.add_argument("date")
    parser.add_argument("--blacklist", default="blacklist.txt")
    parser.add_argument("--reports-dir", default="reports")
    parser.add_argument("--cache", default="r-packages")
    parser.add_argument("--attic-db", default="/var/lib/attic/server.db")
    parser.add_argument("--nix", default="/nix/var/nix/profiles/default/bin/nix")
    args = parser.parse_args()

    outpaths = nix_eval_outpaths(args.date, args.blacklist, args.nix)
    cached = cached_hashes(args.attic_db, args.cache)
    blacklist = read_blacklist(args.blacklist)

    available = []
    missing = []
    store_paths = []
    for name, path in sorted(outpaths.items()):
        if store_hash(path) in cached:
            available.append(name)
            store_paths.append(f"{name}\t{path}")
        else:
            missing.append(name)

    out_dir = Path(args.reports_dir) / args.date
    out_dir.mkdir(parents=True, exist_ok=True)
    write_lines(out_dir / "available.txt", available)
    write_lines(out_dir / "available-store-paths.tsv", store_paths)
    write_lines(out_dir / "missing.txt", missing)
    write_lines(out_dir / "blacklisted.txt", blacklist)

    summary = {
        "date": args.date,
        "cache": args.cache,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "blacklist_file": str(Path(args.blacklist).resolve()),
        "total_evaluated": len(outpaths),
        "available": len(available),
        "missing": len(missing),
        "blacklisted": len(blacklist),
    }
    (out_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n"
    )

    readme = f"""# r-packages cache report: {args.date}

| Metric | Count |
|---|---:|
| Evaluated packages | {len(outpaths)} |
| Available in Attic | {len(available)} |
| Missing from Attic | {len(missing)} |
| Blacklisted | {len(blacklist)} |

Files:

- `available.txt`: package names available in Attic for this date.
- `available-store-paths.tsv`: available package names and exact store paths.
- `missing.txt`: evaluated package names still missing from Attic.
- `blacklisted.txt`: blacklist snapshot used for this report.
- `summary.json`: machine-readable summary.
"""
    (out_dir / "README.md").write_text(readme)

    print(f"report date: {args.date}")
    print(f"evaluated: {len(outpaths)}")
    print(f"available: {len(available)}")
    print(f"missing: {len(missing)}")
    update_index(args.reports_dir)

    print(f"blacklisted: {len(blacklist)}")
    print(f"wrote: {out_dir}")


if __name__ == "__main__":
    main()
