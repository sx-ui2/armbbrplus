#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/.work}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
KERNEL_VERSION="${KERNEL_VERSION:-6.7.9}"
KERNEL_MAJOR="${KERNEL_MAJOR:-6}"
KERNEL_SERIES="${KERNEL_SERIES:-6.7}"
LOCALVERSION="${LOCALVERSION:--bbrplus}"
PKGREV="${PKGREV:-1}"
if command -v nproc >/dev/null 2>&1; then
  DEFAULT_JOBS="$(nproc)"
else
  DEFAULT_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
fi
JOBS="${JOBS:-${DEFAULT_JOBS}}"
SKIP_BUILD="${SKIP_BUILD:-0}"
PATCH_DIR="${ROOT_DIR}/patches/6.7"
FRAGMENT="${ROOT_DIR}/configs/ubuntu2204-arm64.fragment"

SOURCE_ARCHIVE="linux-${KERNEL_VERSION}.tar.xz"
SOURCE_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${SOURCE_ARCHIVE}"
SOURCE_DIR="${WORK_DIR}/linux-${KERNEL_VERSION}"
PATCHED_DIR="${WORK_DIR}/linux-${KERNEL_VERSION}-bbrplus"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

if command -v gmake >/dev/null 2>&1; then
  MAKE_CMD="${MAKE_CMD:-gmake}"
else
  MAKE_CMD="${MAKE_CMD:-make}"
fi

for cmd in curl tar patch "${MAKE_CMD}" rsync sha256sum; do
  require_cmd "$cmd"
done

if [[ "${SKIP_BUILD}" != "1" ]]; then
  require_cmd fakeroot
  require_cmd gcc-aarch64-linux-gnu
fi

rm -rf "${PATCHED_DIR}" "${DIST_DIR}"
mkdir -p "${WORK_DIR}" "${DIST_DIR}"

if [[ ! -f "${WORK_DIR}/${SOURCE_ARCHIVE}" ]]; then
  curl -fL --retry 3 --retry-delay 2 -o "${WORK_DIR}/${SOURCE_ARCHIVE}" "${SOURCE_URL}"
fi

rm -rf "${SOURCE_DIR}"
tar -C "${WORK_DIR}" -xf "${WORK_DIR}/${SOURCE_ARCHIVE}"
cp -a "${SOURCE_DIR}" "${PATCHED_DIR}"

cd "${PATCHED_DIR}"
patch -p1 --forward < "${PATCH_DIR}/convert_official_linux-6.7.x_src_to_bbrplus.patch"

"${MAKE_CMD}" ARCH=arm64 defconfig
"${PATCHED_DIR}/scripts/kconfig/merge_config.sh" -m .config "${FRAGMENT}"
yes "" | "${MAKE_CMD}" ARCH=arm64 olddefconfig

"${PATCHED_DIR}/scripts/config" --disable SECURITY_LOCKDOWN_LSM
"${PATCHED_DIR}/scripts/config" --disable DEBUG_INFO
"${PATCHED_DIR}/scripts/config" --disable MODULE_SIG
yes "" | "${MAKE_CMD}" ARCH=arm64 olddefconfig

if [[ "${SKIP_BUILD}" == "1" ]]; then
  cp .config "${DIST_DIR}/config-${KERNEL_VERSION}${LOCALVERSION}"
  echo "Patch/config preparation completed. Build skipped because SKIP_BUILD=1."
  exit 0
fi

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LOCALVERSION
export KDEB_PKGVERSION="${KERNEL_VERSION}${LOCALVERSION}-${PKGREV}"

"${MAKE_CMD}" -j"${JOBS}" bindeb-pkg

find "${WORK_DIR}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) -exec mv -t "${DIST_DIR}" {} +
cp .config "${DIST_DIR}/config-${KERNEL_VERSION}${LOCALVERSION}"

(
  cd "${DIST_DIR}"
  sha256sum * > sha256sums.txt
)

echo "Build completed. Artifacts are in ${DIST_DIR}"
