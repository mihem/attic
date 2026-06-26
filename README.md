# R Packages Nix Binary Cache

This repository builds and publishes a Nix binary cache for R packages on
`x86_64-linux`.

The package set follows the weekly Monday nixpkgs snapshots used by
[`rix`](https://github.com/ropensci/rix). The available `rix` dates are listed in
[`available_df.csv`](https://github.com/ropensci/rix/blob/main/inst/extdata/available_df.csv).
Starting with `2026-05-18`, this cache is intended to provide binaries for all
weekly Monday `R_NIXPKGS_DATE` updates that are built by this project.

Cache URL:

```text
https://osmzhlab.uni-muenster.de:4949/r-packages
```

Public key:

```text
r-packages:Op7Q3XME8az4XNcP1clupGw4ZbuaguBw+sUziweqpTY=
```

## Reports

Per-date package availability reports are written to [`reports/`](reports/).
Each report contains:

- `available.txt`: package names available in Attic for that date.
- `available-store-paths.tsv`: package names and exact Nix store paths.
- `missing.txt`: evaluated package names still missing from Attic.
- `blacklisted.txt`: blacklist snapshot used for that date.
- `summary.json`: machine-readable counts.

## Use On NixOS

Add the cache as an extra substituter in your NixOS configuration:

```nix
{
  nix.settings = {
    extra-substituters = [
      "https://osmzhlab.uni-muenster.de:4949/r-packages"
    ];

    extra-trusted-public-keys = [
      "r-packages:Op7Q3XME8az4XNcP1clupGw4ZbuaguBw+sUziweqpTY="
    ];
  };
}
```

Then rebuild NixOS:

```bash
sudo nixos-rebuild switch
```

## Use With Nix Or nixpkgs

For a single user or non-NixOS machine, add this to `~/.config/nix/nix.conf`:

```text
extra-substituters = https://osmzhlab.uni-muenster.de:4949/r-packages
extra-trusted-public-keys = r-packages:Op7Q3XME8az4XNcP1clupGw4ZbuaguBw+sUziweqpTY=
```

For a flake-based project, you can also advertise the cache in `flake.nix`:

```nix
{
  nixConfig = {
    extra-substituters = [
      "https://osmzhlab.uni-muenster.de:4949/r-packages"
    ];
    extra-trusted-public-keys = [
      "r-packages:Op7Q3XME8az4XNcP1clupGw4ZbuaguBw+sUziweqpTY="
    ];
  };
}
```

Users still need to accept the flake `nixConfig` prompt, or configure the cache
in their Nix configuration.

## Build Workflow

The main workflow is `weekly-missing.sh`:

```bash
R_NIXPKGS_DATE=2026-05-25 ./weekly-missing.sh
```

It evaluates all non-blacklisted `pkgs.rPackages` derivations for the selected
`R_NIXPKGS_DATE`, checks the Attic database for already cached store paths, and
builds/uploads only paths missing from `r-packages`.

Builds and uploads are handled by
[`nix-fast-build`](https://github.com/Mic92/nix-fast-build) via
`--attic-cache r-packages`. There is no separate manual `attic push` step in the
normal workflow.

Large date jumps can invalidate most store paths. For those cases the workflow
runs in batches and only runs garbage collection if free disk space drops below
the configured threshold:

```bash
R_NIXPKGS_DATE=2026-05-25 BATCH_SIZE=5000 MIN_FREE_GB=300 RUN_GC=auto ./weekly-missing.sh
```

At the end of each run, the workflow writes or updates the matching date report
under `reports/<R_NIXPKGS_DATE>/` and updates `reports/README.md`.

## Attic Chunking

The cache uses Attic content-defined chunking with an `8 MiB` NAR threshold and
`1 MiB` average chunks:

```toml
[chunking]
nar-size-threshold = 8388608
min-size = 262144
avg-size = 1048576
max-size = 4194304
```

This is a compromise between weekly delta storage savings and operational
smoothness for SQLite/NFS-backed Attic storage.

Benchmark setup:

| Item | Value |
|---|---|
| Packages | 50 real Bioconductor outputs |
| Sample size | 952 MiB logical package-output content |
| Test | push `v1`, then push slightly modified `v2` into the same temporary cache |
| Measurement | additional chunks/storage after pushing modified `v2` |

Relevant benchmark result:

| Preset | NAR threshold | Avg chunk | v1 time | v1 chunks | v1 stored | v2 time | v2 new chunks | v2 stored | v2 saving vs no chunking |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| No chunking | disabled | disabled | 7s | 50 | 951 MiB | 7s | 50 | 957 MiB | baseline |
| Current setting | 8 MiB | 1 MiB | 23s | 764 | 942 MiB | 12s | 159 | 258 MiB | 73.0% |

So for weekly-style updates in this benchmark, the selected chunking reduced the
newly stored `v2` data from `957 MiB` to `258 MiB`, while keeping first-upload
chunk count much lower than more aggressive `512 KiB` chunk settings.
