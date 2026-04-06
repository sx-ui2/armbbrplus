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
ORACLE_KERNEL_SERIES="${ORACLE_KERNEL_SERIES:-linux-oracle-6.8}"
ORACLE_BASE_RELEASE="${ORACLE_BASE_RELEASE:-6.8.0-1047-oracle}"
ORACLE_PKG_VERSION="${ORACLE_PKG_VERSION:-6.8.0-1047.48~22.04.1}"
ORACLE_HEADERS_DEB="${ORACLE_HEADERS_DEB:-linux-headers-${ORACLE_BASE_RELEASE}_${ORACLE_PKG_VERSION}_arm64.deb}"
ORACLE_HEADERS_URL="${ORACLE_HEADERS_URL:-https://ports.ubuntu.com/pool/main/l/${ORACLE_KERNEL_SERIES}/${ORACLE_HEADERS_DEB}}"
if command -v nproc >/dev/null 2>&1; then
  DEFAULT_JOBS="$(nproc)"
else
  DEFAULT_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
fi
JOBS="${JOBS:-${DEFAULT_JOBS}}"
SKIP_BUILD="${SKIP_BUILD:-0}"
PATCH_DIR="${ROOT_DIR}/patches/6.7"
FRAGMENT="${ROOT_DIR}/configs/ubuntu2204-arm64.fragment"
ORACLE_HEADERS_PATH="${WORK_DIR}/${ORACLE_HEADERS_DEB}"

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

apply_fragment() {
  local line symbol value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      "${PATCHED_DIR}/scripts/config" --disable "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^CONFIG_([A-Za-z0-9_]+)=y$ ]]; then
      "${PATCHED_DIR}/scripts/config" --enable "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^CONFIG_([A-Za-z0-9_]+)=m$ ]]; then
      "${PATCHED_DIR}/scripts/config" --module "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^CONFIG_([A-Za-z0-9_]+)=\"(.*)\"$ ]]; then
      "${PATCHED_DIR}/scripts/config" --set-str "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      continue
    fi
    if [[ "${line}" =~ ^CONFIG_([A-Za-z0-9_]+)=([0-9]+)$ ]]; then
      "${PATCHED_DIR}/scripts/config" --set-val "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "${FRAGMENT}"
}

if command -v gmake >/dev/null 2>&1; then
  MAKE_CMD="${MAKE_CMD:-gmake}"
else
  MAKE_CMD="${MAKE_CMD:-make}"
fi

for cmd in ar curl patch "${MAKE_CMD}" rsync sha256sum tar zstd; do
  require_cmd "$cmd"
done

if [[ "${SKIP_BUILD}" != "1" ]]; then
  require_cmd fakeroot
  require_cmd aarch64-linux-gnu-gcc
fi

rm -rf "${PATCHED_DIR}" "${DIST_DIR}"
mkdir -p "${WORK_DIR}" "${DIST_DIR}"

if [[ ! -f "${WORK_DIR}/${SOURCE_ARCHIVE}" ]]; then
  curl -fL --retry 3 --retry-delay 2 -o "${WORK_DIR}/${SOURCE_ARCHIVE}" "${SOURCE_URL}"
fi
if [[ ! -f "${ORACLE_HEADERS_PATH}" ]]; then
  curl -fL --retry 3 --retry-delay 2 -o "${ORACLE_HEADERS_PATH}" "${ORACLE_HEADERS_URL}"
fi

rm -rf "${SOURCE_DIR}"
tar -C "${WORK_DIR}" -xf "${WORK_DIR}/${SOURCE_ARCHIVE}"
mv "${SOURCE_DIR}" "${PATCHED_DIR}"

cd "${PATCHED_DIR}"
patch -p1 --forward < "${PATCH_DIR}/convert_official_linux-6.7.x_src_to_bbrplus.patch"

ar p "${ORACLE_HEADERS_PATH}" data.tar.zst | zstd -dc | tar -xOf - "./usr/src/linux-headers-${ORACLE_BASE_RELEASE}/.config" > .config
apply_fragment
"${MAKE_CMD}" ARCH=arm64 olddefconfig </dev/null

"${PATCHED_DIR}/scripts/config" --set-str LOCALVERSION ""
"${PATCHED_DIR}/scripts/config" --disable SECURITY_LOCKDOWN_LSM
"${PATCHED_DIR}/scripts/config" --disable DEBUG_INFO
"${PATCHED_DIR}/scripts/config" --disable MODULE_SIG
"${PATCHED_DIR}/scripts/config" --disable MODULE_SIG_ALL
"${PATCHED_DIR}/scripts/config" --set-str SYSTEM_TRUSTED_KEYS ""
"${PATCHED_DIR}/scripts/config" --set-str SYSTEM_REVOCATION_KEYS ""
"${MAKE_CMD}" ARCH=arm64 olddefconfig </dev/null

if [[ "${SKIP_BUILD}" == "1" ]]; then
  cp .config "${DIST_DIR}/config-${KERNEL_VERSION}${LOCALVERSION}"
  echo "Patch/config preparation completed. Build skipped because SKIP_BUILD=1."
  exit 0
fi

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LOCALVERSION
export KDEB_PKGVERSION="${KERNEL_VERSION}${LOCALVERSION}-${PKGREV}"
export INSTALL_MOD_STRIP=1

"${MAKE_CMD}" -j"${JOBS}" bindeb-pkg

find "${WORK_DIR}" -maxdepth 1 -type f \
  \( -name "*${KERNEL_VERSION}${LOCALVERSION}*.deb" -o -name "*${KERNEL_VERSION}${LOCALVERSION}*.changes" -o -name "*${KERNEL_VERSION}${LOCALVERSION}*.buildinfo" \) \
  -exec mv -t "${DIST_DIR}" {} +
cp .config "${DIST_DIR}/config-${KERNEL_VERSION}${LOCALVERSION}"

# GitHub Releases rejects assets larger than 2 GiB, and the debug package is
# not needed for installation on target VPS instances.
rm -f "${DIST_DIR}"/*-dbg_*.deb

(
  cd "${DIST_DIR}"
  sha256sum * > sha256sums.txt
)

echo "Build completed. Artifacts are in ${DIST_DIR}"
