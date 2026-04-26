#!/usr/bin/env bash
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法:
  sudo bash scripts/install-ubuntu2404-bbrplus-arm64.sh [选项]

选项:
  --dir <目录>          从指定目录读取 .deb 内核包，默认当前目录
  --enable-bbrplus      安装完成后自动启用 bbrplus
  --no-reboot           安装完成后不提示重启
  -h, --help            显示帮助

说明:
  把这个脚本和编译好的 ARM64 内核 .deb 放在同一个目录里最省事。
  目录里通常至少会有:
    linux-image-*.deb
    linux-headers-*.deb
    linux-modules-*.deb

示例:
  sudo bash scripts/install-ubuntu2404-bbrplus-arm64.sh --dir ./dist --enable-bbrplus
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    red "请使用 root 运行。"
    exit 1
  fi
}

require_ubuntu_2404_arm64() {
  local arch version
  arch="$(dpkg --print-architecture)"
  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  if [[ "${arch}" != "arm64" ]]; then
    red "当前架构是 ${arch}，这个脚本只适用于 arm64。"
    exit 1
  fi
  if [[ "${version}" != "24.04" ]]; then
    yellow "当前系统版本是 ${version:-unknown}，这套内核包目标是 Ubuntu 24.04。继续前请确认兼容性。"
  fi
}

install_kernel_debs() {
  local kernel_dir="$1"
  local -a headers_pkgs=()
  local -a modules_pkgs=()
  local -a image_pkgs=()
  local -a extra_pkgs=()

  mapfile -t headers_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f -name 'linux-headers-*.deb' | sort)
  mapfile -t modules_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f -name 'linux-modules-*.deb' | sort)
  mapfile -t image_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f \( -name 'linux-image-*.deb' -o -name 'linux-*image*.deb' \) | sort)
  mapfile -t extra_pkgs < <(find "${kernel_dir}" -maxdepth 1 -type f \( -name 'linux-libc-dev*.deb' -o -name 'linux-tools-*.deb' -o -name 'linux-cloud-tools-*.deb' \) | sort)

  if [[ ${#image_pkgs[@]} -eq 0 ]]; then
    red "在 ${kernel_dir} 里没有找到 linux-image-*.deb。"
    exit 1
  fi

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

main() {
  local kernel_dir="."
  local do_enable_bbrplus=0
  local no_reboot=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        kernel_dir="${2:-}"
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
  require_ubuntu_2404_arm64

  if [[ ! -d "${kernel_dir}" ]]; then
    red "目录不存在: ${kernel_dir}"
    exit 1
  fi

  install_kernel_debs "${kernel_dir}"
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
