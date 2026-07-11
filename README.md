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

## What Is Covered

The cache targets `x86_64-linux` only. It does not provide binaries for
macOS/Darwin systems such as `aarch64-darwin`.

The cache contains binaries for ~ `32,000`
evaluated R package outputs. Another ~`1,300` packages are blacklisted because
they failed to build or evaluate for the package set used here.

Exact coverage by date is listed in [`reports/`](reports/). The numbers can change
between weekly `R_NIXPKGS_DATE` snapshots because nixpkgs package availability
and build failures change over time.

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

## Use On Non-NixOS Systems

For a regular Nix installation on Linux, add this to `~/.config/nix/nix.conf`:

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

Two implementation details are important for speed:

1. Use [`nix-fast-build`](https://github.com/Mic92/nix-fast-build) for parallel
   evaluation/building and direct Attic upload.
2. Optimize Attic chunk size for weekly R/Bioconductor deltas, where many large
   package outputs are similar but not byte-identical across dates.

The workflow uses `nix-fast-build --attic-cache r-packages`. There is no separate
manual `attic push` step in the normal workflow, so cache checking, building, and
uploading stay in one pass.

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
smoothness for PostgreSQL/NFS-backed Attic storage.

Benchmark setup:

| Item | Value |
|---|---|
| Packages | 50 real Bioconductor outputs |
| Sample size | 952 MiB logical package-output content |
| Test | push `v1`, then push a slightly modified `v2` of the same outputs into the same temporary cache |
| Measurement | additional chunks/storage needed for `v2` after `v1` already exists |

Here `v1` and `v2` are not two full weekly cache runs. They are a controlled
weekly-delta simulation: first upload a representative package-output set, then
upload a slightly changed version of those same outputs. This isolates the part
that matters for weekly updates: how much new storage Attic needs when package
outputs change but still share most content with the previous date.

Relevant benchmark results:

| Preset | NAR threshold | Avg chunk | v1 time | v1 chunks | v1 stored | v2 time | v2 new chunks | v2 stored | v2 saving vs no chunking |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| No chunking | disabled | disabled | 7s | 50 | 951 MiB | 7s | 50 | 957 MiB | baseline |
| Aggressive chunking (`th128k-512k`) | 128 KiB | 512 KiB | 47s | 1657 | 935 MiB | 10s | 213 | 142 MiB | 85.2% |
| Current setting (`th8-1m`) | 8 MiB | 1 MiB | 23s | 764 | 942 MiB | 12s | 159 | 258 MiB | 73.0% |

The aggressive `128 KiB / 512 KiB` setting saved the most weekly-delta storage,
but it more than doubled first-upload chunk count compared with the current
setting. For this cache, the selected `8 MiB / 1 MiB` setting is the operational
compromise: large weekly storage savings, fewer PostgreSQL/NFS objects, and faster
first uploads.
