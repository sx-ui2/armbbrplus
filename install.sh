#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-sx-ui2/armbbrplus}"
API_URL="${API_URL:-https://api.github.com/repos/${REPO_SLUG}/releases}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法:
  sudo bash install.sh [选项]

选项:
  --tag <release-tag>   指定 release tag，默认自动匹配最新可用版本
  --enable-bbrplus      安装完成后自动启用 bbrplus
  --no-reboot           安装完成后不提示重启
  -h, --help            显示帮助

说明:
  这个脚本会自动识别当前 Ubuntu 版本和架构，只支持：
    - Ubuntu 22.04 ARM64
    - Ubuntu 24.04 ARM64
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || { red "请使用 root 运行。"; exit 1; }
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    red "缺少命令: $1"
    exit 1
  }
}

detect_target() {
  local arch version
  arch="$(dpkg --print-architecture)"
  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"

  [[ "${arch}" == "arm64" ]] || {
    red "当前架构是 ${arch}，这个一键脚本目前只支持 arm64。"
    exit 1
  }

  case "${version}" in
    22.04)
      TARGET_NAME="Ubuntu 22.04 ARM64"
      TARGET_SUFFIX="-bbrplus"
      ;;
    24.04)
      TARGET_NAME="Ubuntu 24.04 ARM64"
      TARGET_SUFFIX="-bbrplus-ubuntu2404"
      ;;
    *)
      red "当前系统版本是 ${version:-unknown}，这个一键脚本目前只支持 Ubuntu 22.04 / 24.04 ARM64。"
      exit 1
      ;;
  esac
}

resolve_release_tag() {
  local requested_tag="${1:-}"
  if [[ -n "${requested_tag}" ]]; then
    RELEASE_TAG="${requested_tag}"
    return
  fi

  RELEASE_TAG="$(
    python3 - "${API_URL}" "${TARGET_SUFFIX}" <<'PY'
import json, sys, urllib.request
url, suffix = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
tags = [item.get("tag_name", "") for item in data if item.get("tag_name", "").endswith(suffix)]
if not tags:
    sys.exit(1)
def norm(tag: str):
    core = tag.removesuffix(suffix)
    parts = []
    for piece in core.split("."):
        try:
            parts.append(int(piece))
        except ValueError:
            parts.append(piece)
    return parts
tags.sort(key=norm, reverse=True)
print(tags[0])
PY
  )" || {
    red "无法从 ${REPO_SLUG} 找到匹配 ${TARGET_NAME} 的 release。"
    exit 1
  }
}

download_release_assets() {
  local workdir="$1"
  python3 - "${API_URL}/tags/${RELEASE_TAG}" "${workdir}" <<'PY'
import json, os, sys, urllib.request
url, workdir = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
assets = [a for a in data.get("assets", []) if a.get("name", "").endswith(".deb")]
if not assets:
    sys.stderr.write("release has no .deb assets\n")
    sys.exit(1)
for asset in assets:
    asset_url = asset["browser_download_url"]
    path = os.path.join(workdir, asset["name"])
    with urllib.request.urlopen(asset_url) as src, open(path, "wb") as dst:
        dst.write(src.read())
PY
}

install_kernel_debs() {
  local kernel_dir="$1"
  local -a headers_pkgs=() modules_pkgs=() image_pkgs=() extra_pkgs=()

  mapfile -t headers_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f -name 'linux-headers-*.deb' | sort)
  mapfile -t modules_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f -name 'linux-modules-*.deb' | sort)
  mapfile -t image_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f \( -name 'linux-image-*.deb' -o -name 'linux-*image*.deb' \) | sort)
  mapfile -t extra_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f \( -name 'linux-libc-dev*.deb' -o -name 'linux-tools-*.deb' -o -name 'linux-cloud-tools-*.deb' \) | sort)

  [[ ${#image_pkgs[@]} -gt 0 ]] || {
    red "release 里没有找到 linux-image-*.deb。"
    exit 1
  }

  yellow "准备安装这些内核包："
  printf '  %s\n' "${headers_pkgs[@]}" "${modules_pkgs[@]}" "${image_pkgs[@]}" "${extra_pkgs[@]}" | sed '/^  $/d'

  dpkg -i "${headers_pkgs[@]}" "${modules_pkgs[@]}" "${image_pkgs[@]}" "${extra_pkgs[@]}"
  apt-get -f install -y
}

refresh_boot_files() {
  yellow "更新 initramfs 和引导项..."
  update-initramfs -c -k all || update-initramfs -u -k all
  update-grub || true
  if command -v flash-kernel >/dev/null 2>&1; then
    flash-kernel || true
  fi
}

enable_bbrplus() {
  cat >/etc/sysctl.d/99-bbrplus.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbrplus
EOF
  sysctl --system >/dev/null
  green "已写入 /etc/sysctl.d/99-bbrplus.conf 并尝试启用 bbrplus。"
}

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
}

main() {
  local requested_tag="" do_enable_bbrplus=0 no_reboot=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        requested_tag="${2:-}"
        shift 2
        ;;
      --enable-bbrplus)
        do_enable_bbrplus=1
        shift
        ;;
      --no-reboot)
        no_reboot=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        red "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done

  require_root
  require_cmd curl
  require_cmd dpkg
  require_cmd apt-get
  require_cmd python3
  detect_target
  resolve_release_tag "${requested_tag}"

  WORK_DIR="$(mktemp -d /tmp/armbbrplus-install.XXXXXX)"
  trap cleanup EXIT

  yellow "检测到目标系统: ${TARGET_NAME}"
  yellow "准备安装 release: ${RELEASE_TAG}"
  download_release_assets "${WORK_DIR}"
  install_kernel_debs "${WORK_DIR}"
  refresh_boot_files

  if [[ ${do_enable_bbrplus} -eq 1 ]]; then
    enable_bbrplus
  fi

  green "安装流程已完成。"
  yellow "当前运行中的内核仍然是: $(uname -r)"
  if [[ ${no_reboot} -eq 0 ]]; then
    yellow "请执行 reboot，重启后再用 uname -r 确认新内核是否生效。"
  fi
}

main "$@"
