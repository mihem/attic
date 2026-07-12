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
SCMISC_COMMIT_URL = "https://api.github.com/repos/mihem/scMisc/commits/master"
SCMISC_ARCHIVE_URL = "https://github.com/mihem/scMisc/archive/{rev}.tar.gz"
PERMFDP_COMMIT_URL = "https://api.github.com/repos/steven-shuken/permFDP/commits/master"
PERMFDP_ARCHIVE_URL = "https://github.com/steven-shuken/permFDP/archive/{rev}.tar.gz"


def latest_rix_date():
    with urlopen(RIX_DATES_URL, timeout=60) as response:
        rows = list(
            csv.DictReader(line.decode("utf-8") for line in response.readlines())
        )
    if not rows or "date" not in rows[-1]:
        raise RuntimeError("could not read latest rix date")
    return rows[-1]["date"]


def latest_commit(commit_url):
    request = Request(
        commit_url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "attic-weekly-missing",
        },
    )
    with urlopen(request, timeout=60) as response:
        data = json.load(response)
    sha = data.get("sha")
    if not sha:
        raise RuntimeError("could not read latest BPCells commit SHA")
    return sha


def prefetch_sha256(nix, archive_url, rev):
    url = archive_url.format(rev=rev)
    result = subprocess.run(
        [nix, "store", "prefetch-file", "--json", "--unpack", url],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(f"failed to prefetch {url}\n{result.stdout}{result.stderr}")
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
    parser.add_argument("--sc-misc-rev", default="")
    parser.add_argument("--sc-misc-sha256", default="")
    parser.add_argument("--perm-fdp-rev", default="")
    parser.add_argument("--perm-fdp-sha256", default="")
    args = parser.parse_args()

    r_nixpkgs_date = args.r_nixpkgs_date or latest_rix_date()
    bp_cells_rev = args.bp_cells_rev or latest_commit(BPCELLS_COMMIT_URL)
    bp_cells_sha256 = args.bp_cells_sha256 or prefetch_sha256(
        args.nix, BPCELLS_ARCHIVE_URL, bp_cells_rev
    )
    sc_misc_rev = args.sc_misc_rev or latest_commit(SCMISC_COMMIT_URL)
    sc_misc_sha256 = args.sc_misc_sha256 or prefetch_sha256(
        args.nix, SCMISC_ARCHIVE_URL, sc_misc_rev
    )
    perm_fdp_rev = args.perm_fdp_rev or latest_commit(PERMFDP_COMMIT_URL)
    perm_fdp_sha256 = args.perm_fdp_sha256 or prefetch_sha256(
        args.nix, PERMFDP_ARCHIVE_URL, perm_fdp_rev
    )

    print(shell_assign("R_NIXPKGS_DATE", r_nixpkgs_date))
    print(shell_assign("BP_CELLS_REV", bp_cells_rev))
    print(shell_assign("BP_CELLS_SHA256", bp_cells_sha256))
    print(shell_assign("SC_MISC_REV", sc_misc_rev))
    print(shell_assign("SC_MISC_SHA256", sc_misc_sha256))
    print(shell_assign("PERM_FDP_REV", perm_fdp_rev))
    print(shell_assign("PERM_FDP_SHA256", perm_fdp_sha256))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
