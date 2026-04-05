# armbbrplus

GitHub Actions auto-builds an Ubuntu 22.04 compatible ARM64 `6.7.9-bbrplus` kernel package set.

This repository keeps the `6.7.x` BBRplus conversion patch inside the repo and builds from the official Linux `6.7.9` source tarball from `kernel.org`, so the workflow does not depend on a third-party patch URL at build time.
To improve Oracle Cloud ARM compatibility, the build now imports the official Ubuntu Oracle ARM64 kernel config from the published `linux-headers-6.8.0-1047-oracle` package and layers the minimal BBRplus delta on top of that baseline.

## What It Builds

- ARM64 `.deb` kernel packages
- matching headers package
- build metadata (`.buildinfo`, `.changes`)
- a saved `.config`
- a `sha256sums.txt`

## Current Baseline

- Target distro: Ubuntu 22.04 ARM64
- Kernel line: Linux 6.7
- Default kernel version: `6.7.9`
- Oracle config baseline: `6.8.0-1047-oracle`
- Resulting kernel release suffix: `-bbrplus`

This repo is aligned to the public `6.7.9-bbrplus` patch line from `UJX6N/bbrplus-6.x_stable`. The workflow is intentionally pinned to `6.7.9`, because the vendored patch is for the `6.7.x` source line.

## Workflow

The workflow lives at:

- `.github/workflows/build-ubuntu2204-bbrplus-arm64.yml`

It supports:

- `push` to `main`: build and upload workflow artifacts
- `workflow_dispatch`: manual build, with optional GitHub release publishing

## Manual Run

Open:

- `Actions -> Build Ubuntu 22.04 BBRplus ARM64 Kernel -> Run workflow`

Inputs:

- `kernel_version`: defaults to `6.7.9`
- `publish_release`: whether to upload the generated packages to a GitHub release

When `publish_release` is enabled, the workflow creates or updates a release named like:

- `6.7.9-bbrplus`

## Local Build

```bash
sudo apt-get update
sudo apt-get install -y \
  bc bison build-essential ca-certificates cpio debhelper devscripts dwarves \
  fakeroot flex git kmod libelf-dev libncurses-dev libssl-dev lz4 pahole \
  python3 rsync xz-utils zstd gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

KERNEL_VERSION=6.7.9 bash scripts/build-ubuntu2204-bbrplus-arm64.sh
```

Artifacts will be written into:

- `dist/`

## Patch Source

The vendored BBRplus patch set under `patches/6.7/` is based on:

- `UJX6N/bbrplus-6.x_stable`
- `convert_official_linux-6.7.x_src_to_bbrplus.patch`

The original upstream note is preserved in:

- `patches/6.7/README-upstream.txt`

## Oracle Baseline Source

The ARM64 config baseline is extracted at build time from Canonical's published Oracle kernel headers package:

- `https://ports.ubuntu.com/pool/main/l/linux-oracle-6.8/linux-headers-6.8.0-1047-oracle_6.8.0-1047.48~22.04.1_arm64.deb`
