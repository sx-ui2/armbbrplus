# armbbrplus

GitHub Actions auto-builds an Ubuntu 22.04 compatible ARM64 `6.8.x-bbrplus` kernel package set.

This repository keeps the `6.8.x` BBRplus conversion patch inside the repo and builds from the official Linux `6.8.x` source tarball from `kernel.org`, so the workflow does not depend on a third-party patch URL at build time.
To improve Oracle Cloud ARM compatibility, the build now imports the official Ubuntu Oracle ARM64 kernel config from the published `linux-headers-6.8.0-1047-oracle` package and layers the minimal BBRplus delta on top of that baseline.

## What It Builds

- ARM64 `.deb` kernel packages
- matching headers package
- build metadata (`.buildinfo`, `.changes`)
- a saved `.config`
- a `sha256sums.txt`

## Current Baseline

- Target distro: Ubuntu 22.04 ARM64
- Kernel line: Linux 6.8
- Default kernel version: auto-detect latest `6.8.x`
- Oracle config baseline: `6.8.0-1047-oracle`
- Resulting kernel release suffix: `-bbrplus`

This repo is aligned to the public `6.8.x-bbrplus` patch line from `UJX6N/bbrplus-6.x_stable`. The workflow now auto-detects the newest upstream `6.8.x` stable release from `kernel.org`, while still using the vendored `6.8.x` patch in this repository.

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

- `kernel_version`: optional, leave blank to auto-pick the latest `6.8.x`
- `publish_release`: whether to upload the generated packages to a GitHub release

When `publish_release` is enabled, the workflow creates or updates a release named like:

- `6.8.12-bbrplus`

There is also a weekly scheduled run that checks `kernel.org` for the newest `6.8.x` and refreshes the corresponding release automatically.

## Local Build

```bash
sudo apt-get update
sudo apt-get install -y \
  bc bison build-essential ca-certificates cpio debhelper devscripts dwarves \
  fakeroot flex git kmod libelf-dev libncurses-dev libssl-dev lz4 pahole \
  python3 rsync xz-utils zstd gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

KERNEL_VERSION=6.8.12 bash scripts/build-ubuntu2204-bbrplus-arm64.sh
```

Artifacts will be written into:

- `dist/`

## Install On Another ARM Machine

把 release 里的 `.deb` 文件下载到目标 Ubuntu 22.04 ARM64 机器后，可以直接用仓库自带脚本安装：

```bash
sudo bash scripts/install-ubuntu2204-bbrplus-arm64.sh --dir ./dist --enable-bbrplus
```

如果你把脚本和 `.deb` 放在同一个目录，也可以：

```bash
cd /path/to/kernel-debs
sudo bash install-ubuntu2204-bbrplus-arm64.sh --enable-bbrplus
```

脚本会自动：

- 安装 `linux-image / linux-headers / linux-modules`
- 补跑 `apt-get -f install`
- 更新 `initramfs`
- 更新 `grub`
- 如果系统带 `flash-kernel` 也会顺手执行

安装完成后需要重启，再确认：

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
```

## Patch Source

The vendored BBRplus patch set under `patches/6.8/` is based on:

- `UJX6N/bbrplus-6.x_stable`
- `convert_official_linux-6.7.x_src_to_bbrplus.patch`

The original upstream note is preserved in:

- `patches/6.7/README-upstream.txt`

## Oracle Baseline Source

The ARM64 config baseline is extracted at build time from Canonical's published Oracle kernel headers package:

- `https://ports.ubuntu.com/pool/main/l/linux-oracle-6.8/linux-headers-6.8.0-1047-oracle_6.8.0-1047.48~22.04.1_arm64.deb`
