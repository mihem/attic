#!/usr/bin/env python3
import argparse
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
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


def narinfo(path, upstream_store, timeout=30, retries=2):
    store_path_hash = path.split("/nix/store/", 1)[1].split("-", 1)[0]
    url = f"{upstream_store.rstrip('/')}/{store_path_hash}.narinfo"
    request = Request(url, headers={"User-Agent": "attic-weekly-missing"})
    for attempt in range(retries + 1):
        try:
            with urlopen(request, timeout=timeout) as response:
                fields = {}
                for line in response.read().decode().splitlines():
                    key, separator, value = line.partition(": ")
                    if separator:
                        fields[key] = value
                return (
                    path,
                    int(fields.get("FileSize", 0)),
                    int(fields.get("NarSize", 0)),
                )
        except HTTPError as error:
            if error.code == 404:
                return path, None, None
            if attempt == retries:
                raise
        except (TimeoutError, URLError):
            if attempt == retries:
                raise
    raise RuntimeError(f"failed to query {url}")


def upstream_cached_paths(
    paths,
    upstream_store,
    workers=16,
    progress_every=500,
    timeout=30,
    retries=2,
):
    paths = sorted(set(paths))
    cached = set()
    file_bytes = 0
    nar_bytes = 0
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(narinfo, path, upstream_store, timeout, retries)
            for path in paths
        ]
        for completed, future in enumerate(as_completed(futures), 1):
            path, file_size, nar_size = future.result()
            if file_size is not None:
                cached.add(path)
                file_bytes += file_size
                nar_bytes += nar_size
            if progress_every > 0 and (
                completed % progress_every == 0 or completed == len(paths)
            ):
                elapsed = int(time.monotonic() - started)
                print(
                    f"upstream cache: checked {completed}/{len(paths)}, "
                    f"available={len(cached)}, elapsed={elapsed}s",
                    flush=True,
                )
    return cached, file_bytes, nar_bytes


def main():
    parser = argparse.ArgumentParser(
        description="Run a read-only Attic database query."
    )
    parser.add_argument("database")
    parser.add_argument("sql")
    parser.add_argument("--tabs", action="store_true")
    args = parser.parse_args()
    print(query(args.database, args.sql, tabs=args.tabs), end="")


if __name__ == "__main__":
    main()
