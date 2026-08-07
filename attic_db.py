#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from urllib.parse import urlparse


def backend(database):
    scheme = urlparse(database).scheme
    if scheme in ("postgres", "postgresql"):
        return "postgresql"
    if scheme in ("", "sqlite"):
        return "sqlite"
    raise ValueError(f"Unsupported database URL scheme: {scheme}")


def sqlite_path(database):
    if backend(database) != "sqlite":
        raise ValueError("Not a SQLite database")
    if database.startswith("sqlite://"):
        return database.removeprefix("sqlite://").split("?", 1)[0]
    return database


def command(database, query, tabs=False):
    no_sudo = os.environ.get("ATTIC_DB_NO_SUDO") == "1"
    if backend(database) == "sqlite":
        prefix = [] if no_sudo else ["sudo"]
        cmd = prefix + [
            "sqlite3",
            "-readonly",
            "-cmd",
            ".timeout 60000",
        ]
        if tabs:
            cmd.append("-tabs")
        return cmd + [sqlite_path(database), query]

    prefix = []
    if not no_sudo:
        prefix = ["sudo", "-u", os.environ.get("ATTIC_DB_OS_USER", "attic")]
    return prefix + [
        "psql",
        "--no-psqlrc",
        "--quiet",
        "--tuples-only",
        "--no-align",
        "--set",
        "ON_ERROR_STOP=1",
        "--field-separator",
        "\t" if tabs else "|",
        database,
        "--command",
        query,
    ]


def query(database, sql, tabs=False):
    result = subprocess.run(
        command(database, sql, tabs=tabs),
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return result.stdout


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def cached_hashes(database, cache_name):
    sql = f"""
      select o.store_path_hash
      from object o
      join cache c on c.id = o.cache_id
      where c.name = {sql_string(cache_name)};
    """
    return set(query(database, sql).splitlines())


def upstream_cached_paths(nix, paths, upstream_store, batch_size=500):
    cached = set()
    paths = sorted(set(paths))
    for offset in range(0, len(paths), batch_size):
        batch = paths[offset : offset + batch_size]
        result = subprocess.run(
            [nix, "path-info", "--store", upstream_store, "--json", *batch],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            info = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                f"could not query upstream cache {upstream_store}: {result.stderr.strip()}"
            ) from error
        cached.update(path for path, value in info.items() if value is not None)
    return cached


def main():
    parser = argparse.ArgumentParser(description="Run a read-only Attic database query.")
    parser.add_argument("database")
    parser.add_argument("sql")
    parser.add_argument("--tabs", action="store_true")
    args = parser.parse_args()
    print(query(args.database, args.sql, tabs=args.tabs), end="")


if __name__ == "__main__":
    main()
