#!/usr/bin/env python3
import argparse
import csv
import json
import shlex
import subprocess
import sys
from urllib.request import Request, urlopen


RIX_DATES_URL = "https://raw.githubusercontent.com/ropensci/rix/refs/heads/main/inst/extdata/available_df.csv"
BPCELLS_COMMIT_URL = "https://api.github.com/repos/bnprks/BPCells/commits/main"
BPCELLS_ARCHIVE_URL = "https://github.com/bnprks/BPCells/archive/{rev}.tar.gz"


def latest_rix_date():
    with urlopen(RIX_DATES_URL, timeout=60) as response:
        rows = list(csv.DictReader(line.decode("utf-8") for line in response.readlines()))
    if not rows or "date" not in rows[-1]:
        raise RuntimeError("could not read latest rix date")
    return rows[-1]["date"]


def latest_bpcells_rev():
    request = Request(
        BPCELLS_COMMIT_URL,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "attic-weekly-missing"},
    )
    with urlopen(request, timeout=60) as response:
        data = json.load(response)
    sha = data.get("sha")
    if not sha:
        raise RuntimeError("could not read latest BPCells commit SHA")
    return sha


def prefetch_bpcells_sha256(nix, rev):
    url = BPCELLS_ARCHIVE_URL.format(rev=rev)
    result = subprocess.run(
        [nix, "store", "prefetch-file", "--json", "--unpack", url],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"failed to prefetch BPCells source archive: {url}\n{result.stdout}{result.stderr}"
        )
    data = json.loads(result.stdout)
    hash_value = data.get("hash")
    if not hash_value:
        raise RuntimeError("nix prefetch output did not contain a hash")
    return hash_value


def shell_assign(name, value):
    return f"{name}={shlex.quote(value)}"


def main():
    parser = argparse.ArgumentParser(description="Resolve weekly cache input pins.")
    parser.add_argument("--nix", required=True)
    parser.add_argument("--r-nixpkgs-date", default="")
    parser.add_argument("--bp-cells-rev", default="")
    parser.add_argument("--bp-cells-sha256", default="")
    args = parser.parse_args()

    r_nixpkgs_date = args.r_nixpkgs_date or latest_rix_date()
    bp_cells_rev = args.bp_cells_rev or latest_bpcells_rev()
    bp_cells_sha256 = args.bp_cells_sha256 or prefetch_bpcells_sha256(args.nix, bp_cells_rev)

    print(shell_assign("R_NIXPKGS_DATE", r_nixpkgs_date))
    print(shell_assign("BP_CELLS_REV", bp_cells_rev))
    print(shell_assign("BP_CELLS_SHA256", bp_cells_sha256))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
