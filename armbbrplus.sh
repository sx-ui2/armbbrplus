#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-sx-ui2/armbbrplus}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com/repos/${REPO_SLUG}}"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }
plain() { printf '%s\n' "$*"; }

info() { green "[信息] $*"; }
warn() { yellow "[注意] $*"; }
fail() { red "[错误] $*"; exit 1; }

usage() {
  cat <<'EOF'
用法:
  sudo bash armbbrplus.sh
  sudo bash armbbrplus.sh <command>

命令:
  install-bbrplus, --install-bbrplus     ARM64 安装本仓库 Release 里的 BBRplus 内核
  enable-bbrplus, --enable-bbrplus       写入 bbrplus + fq 配置
  enable-bbr, --enable-bbr               写入 bbr + fq 配置
  optimize, tcp-tune, op0, op1, op2       TCP 窗口优化，保留当前拥塞控制算法
  forwarding, --forwarding               开启 IPv4/IPv6 内核转发
  ulimit, --ulimit                       系统资源限制优化
  ban-ping, --ban-ping                   屏蔽 IPv4/IPv6 Ping
  unban-ping, --unban-ping               恢复 IPv4/IPv6 Ping
  status, --status                       查看当前状态
  help, -h, --help                       查看帮助

说明:
  - 这个脚本是自包含版本，不再下载或修补外部加速脚本。
  - ARM64 的 BBRplus 内核来自 sx-ui2/armbbrplus 的 GitHub Release。
  - AMD64 可使用内置 BBR/网络优化功能；本仓库不提供 AMD64 BBRplus 内核包。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "请使用 root 运行。"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_system() {
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${ARCH}" in
    aarch64) ARCH="arm64" ;;
    x86_64) ARCH="amd64" ;;
  esac

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-unknown}"
    VERSION_ID="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_NAME="unknown"
    VERSION_ID="unknown"
  fi
}

ensure_dependencies() {
  local missing=()
  local cmd
  for cmd in curl python3 dpkg find sort awk sed; do
    command_exists "${cmd}" || missing+=("${cmd}")
  done

  if ((${#missing[@]} == 0)); then
    return
  fi

  if command_exists apt-get; then
    info "安装必要依赖: ${missing[*]}"
    apt-get update
    apt-get install -y ca-certificates curl python3 dpkg coreutils findutils gawk sed
  else
    fail "缺少命令: ${missing[*]}，且当前系统没有 apt-get，无法自动安装。"
  fi
}

apply_sysctl_file() {
  local file="$1"
  if command_exists sysctl; then
    sysctl -p "${file}" >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
  fi
}

write_sysctl_file() {
  local file="$1"
  local content="$2"
  mkdir -p /etc/sysctl.d
  cat >"${file}" <<EOF
${content}
EOF
  apply_sysctl_file "${file}"
}

current_congestion_control() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'bbr\n'
}

current_qdisc() {
  sysctl -n net.core.default_qdisc 2>/dev/null || printf 'fq\n'
}

enable_bbrplus() {
  write_sysctl_file /etc/sysctl.d/99-bbrplus.conf \
"net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus"

  local current available
  current="$(current_congestion_control)"
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ "${current}" == "bbrplus" ]]; then
    info "BBRplus 已启用。"
  elif [[ "${available}" == *"bbrplus"* ]]; then
    warn "已写入 BBRplus 配置，但当前仍是 ${current}。可以重启或手动执行 sysctl --system 后再检查。"
  else
    warn "已写入 BBRplus 配置，但当前内核还不支持 bbrplus。安装 BBRplus 内核并重启后会生效。"
  fi
}

enable_bbr() {
  write_sysctl_file /etc/sysctl.d/99-bbr.conf \
"net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"

  local current
  current="$(current_congestion_control)"
  if [[ "${current}" == "bbr" ]]; then
    info "BBR 已启用。"
  else
    warn "已写入 BBR 配置，当前拥塞控制是 ${current}。如果内核支持 BBR，重启或 sysctl --system 后会生效。"
  fi
}

tcp_window_tune() {
  local cc qdisc
  cc="$(current_congestion_control)"
  qdisc="$(current_qdisc)"
  [[ -z "${cc}" || "${cc}" == "unknown" ]] && cc="bbr"
  [[ -z "${qdisc}" || "${qdisc}" == "unknown" ]] && qdisc="fq"

  write_sysctl_file /etc/sysctl.d/99-sxui-tcp-window.conf \
"net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rmem = 4096 65536 37331520
net.ipv4.tcp_wmem = 4096 65536 37331520
net.core.rmem_max = 37331520
net.core.wmem_max = 37331520
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = ${cc}"

  info "TCP 窗口优化已应用，保留当前拥塞控制: ${cc}，队列算法: ${qdisc}。"
}

enable_forwarding() {
  write_sysctl_file /etc/sysctl.d/99-sxui-forwarding.conf \
"net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2"

  info "IPv4/IPv6 内核转发已开启。"
  warn "这只开启内核转发能力；如果要做 NAT/端口转发，还需要单独配置 nftables/iptables 规则。"
}

ban_ping() {
  write_sysctl_file /etc/sysctl.d/99-sxui-icmp.conf \
"net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.icmp.echo_ignore_all = 1"
  info "已尝试屏蔽 IPv4/IPv6 Ping。"
}

unban_ping() {
  write_sysctl_file /etc/sysctl.d/99-sxui-icmp.conf \
"net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 0
net.ipv6.icmp.echo_ignore_all = 0"
  info "已尝试恢复 IPv4/IPv6 Ping。"
}

ulimit_tune() {
  mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/profile.d

  write_sysctl_file /etc/sysctl.d/99-sxui-filelimit.conf \
"fs.file-max = 1000000
fs.nr_open = 1000000"

  cat >/etc/security/limits.d/99-sxui-network-tools.conf <<'EOF'
root soft nofile 1000000
root hard nofile 1000000
root soft nproc 1000000
root hard nproc 1000000
root soft core unlimited
root hard core unlimited
root soft memlock unlimited
root hard memlock unlimited

* soft nofile 1000000
* hard nofile 1000000
* soft nproc 1000000
* hard nproc 1000000
* soft core unlimited
* hard core unlimited
* soft memlock unlimited
* hard memlock unlimited
EOF

  cat >/etc/profile.d/99-sxui-ulimit.sh <<'EOF'
#!/usr/bin/env sh
ulimit -SHn 1000000 2>/dev/null || true
ulimit -c unlimited 2>/dev/null || true
EOF
  chmod +x /etc/profile.d/99-sxui-ulimit.sh

  if [[ -f /etc/pam.d/common-session ]] && ! grep -q 'pam_limits.so' /etc/pam.d/common-session; then
    printf '\nsession required pam_limits.so\n' >>/etc/pam.d/common-session
  fi

  cat >/etc/systemd/system.conf.d/99-sxui-network-tools.conf <<'EOF'
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=1000000
DefaultLimitNPROC=1000000
EOF

  ulimit -SHn 1000000 2>/dev/null || true
  ulimit -c unlimited 2>/dev/null || true

  if command_exists systemctl; then
    systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  info "系统资源限制优化已写入。新登录会话和新启动的 systemd 服务会使用新限制。"
}

release_suffix_for_system() {
  detect_system
  [[ "${ARCH}" == "arm64" ]] || fail "本仓库 BBRplus 内核只提供 ARM64 包；当前架构是 ${ARCH}。"
  [[ "${OS_ID}" == "ubuntu" ]] || fail "ARM64 BBRplus 自动安装当前只支持 Ubuntu 22.04 / 24.04。"

  case "${VERSION_ID}" in
    22.04) printf '%s\n' "-bbrplus" ;;
    24.04) printf '%s\n' "-bbrplus-ubuntu2404" ;;
    *) fail "当前系统是 Ubuntu ${VERSION_ID}，只支持 22.04 / 24.04。" ;;
  esac
}

find_latest_release_tag() {
  local suffix="$1"
  python3 - "${GITHUB_API_BASE}/releases?per_page=100" "${suffix}" <<'PY'
import json
import re
import sys
import urllib.request

url, suffix = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    url,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "sx-ui2-armbbrplus-installer",
    },
)
with urllib.request.urlopen(req, timeout=45) as resp:
    data = json.load(resp)

tags = []
for item in data:
    tag = item.get("tag_name", "")
    if item.get("draft"):
        continue
    if tag.endswith(suffix):
        tags.append(tag)

if not tags:
    raise SystemExit(2)

def version_key(tag):
    core = tag[: -len(suffix)] if suffix and tag.endswith(suffix) else tag
    return [int(part) for part in re.findall(r"\d+", core)]

tags.sort(key=version_key, reverse=True)
print(tags[0])
PY
}

download_release_debs() {
  local tag="$1"
  local workdir="$2"
  python3 - "${GITHUB_API_BASE}" "${tag}" "${workdir}" <<'PY'
import json
import os
import shutil
import sys
import urllib.parse
import urllib.request

api_base, tag, workdir = sys.argv[1], sys.argv[2], sys.argv[3]
url = api_base + "/releases/tags/" + urllib.parse.quote(tag, safe="")
req = urllib.request.Request(
    url,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "sx-ui2-armbbrplus-installer",
    },
)
with urllib.request.urlopen(req, timeout=45) as resp:
    release = json.load(resp)

assets = [asset for asset in release.get("assets", []) if asset.get("name", "").endswith(".deb")]
if not assets:
    sys.stderr.write("release has no .deb assets\n")
    raise SystemExit(3)

if not any("linux-image" in asset.get("name", "") for asset in assets):
    sys.stderr.write("release has no linux-image .deb asset\n")
    raise SystemExit(4)

os.makedirs(workdir, exist_ok=True)
for asset in assets:
    name = os.path.basename(asset["name"])
    dest = os.path.join(workdir, name)
    print("[下载] " + name)
    with urllib.request.urlopen(asset["browser_download_url"], timeout=120) as src, open(dest, "wb") as out:
        shutil.copyfileobj(src, out)
PY
}

install_deb_packages() {
  local workdir="$1"
  local headers_pkgs=()
  local modules_pkgs=()
  local image_pkgs=()
  local extra_pkgs=()
  local debs=()

  mapfile -t headers_pkgs < <(find "${workdir}" -maxdepth 1 -type f -name "linux-headers-*.deb" | sort)
  mapfile -t modules_pkgs < <(find "${workdir}" -maxdepth 1 -type f -name "linux-modules-*.deb" | sort)
  mapfile -t image_pkgs < <(find "${workdir}" -maxdepth 1 -type f \( -name "linux-image-*.deb" -o -name "linux-*image*.deb" \) | sort)
  mapfile -t extra_pkgs < <(find "${workdir}" -maxdepth 1 -type f \( -name "linux-libc-dev*.deb" -o -name "linux-tools-*.deb" -o -name "linux-cloud-tools-*.deb" \) | sort)

  ((${#image_pkgs[@]} > 0)) || fail "release 里没有找到 linux-image-*.deb。"

  debs=("${headers_pkgs[@]}" "${modules_pkgs[@]}" "${image_pkgs[@]}" "${extra_pkgs[@]}")
  info "开始安装内核包..."
  if ! dpkg -i "${debs[@]}"; then
    warn "dpkg 返回依赖错误，尝试 apt-get -f install 修复。"
    apt-get -f install -y
  fi
}

refresh_bootloader() {
  if command_exists update-initramfs; then
    update-initramfs -u -k all >/dev/null 2>&1 || warn "update-initramfs 执行失败，请手动检查。"
  fi
  if command_exists update-grub; then
    update-grub || warn "update-grub 执行失败，请手动检查。"
  elif command_exists grub2-mkconfig; then
    grub2-mkconfig -o /boot/grub2/grub.cfg || warn "grub2-mkconfig 执行失败，请手动检查。"
  fi
  if command_exists flash-kernel; then
    flash-kernel >/dev/null 2>&1 || true
  fi
}

install_arm64_bbrplus_kernel() {
  ensure_dependencies
  detect_system

  local suffix tag workdir
  suffix="$(release_suffix_for_system)"
  tag="$(find_latest_release_tag "${suffix}")" || fail "没有找到匹配 ${suffix} 的 release。"

  info "ARM64 BBRplus 将使用 release: ${tag}"
  workdir="$(mktemp -d /tmp/armbbrplus.XXXXXX)"

  download_release_debs "${tag}" "${workdir}" || fail "下载 release 资产失败。"
  install_deb_packages "${workdir}"
  rm -rf "${workdir}"
  refresh_bootloader
  enable_bbrplus

  green "BBRplus 内核安装完成。"
  yellow "请重启服务器后确认：uname -r && sysctl net.ipv4.tcp_congestion_control"
}

show_kernels() {
  plain "当前内核: $(uname -r)"
  if command_exists dpkg-query; then
    plain ""
    plain "已安装 linux-image 包:"
    dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image*' 2>/dev/null | sort || true
  fi
}

show_status() {
  detect_system

  local virt cc qdisc available ip4_forward ip6_forward route_localnet ping4 ping6
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -z "${virt}" || "${virt}" == "none" ]] && virt="unknown"
  cc="$(current_congestion_control)"
  qdisc="$(current_qdisc)"
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  ip4_forward="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  ip6_forward="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true)"
  route_localnet="$(sysctl -n net.ipv4.conf.all.route_localnet 2>/dev/null || true)"
  ping4="$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || true)"
  ping6="$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || true)"

  plain "------------------------------------------------------------"
  blue "系统: ${OS_NAME}    架构: ${ARCH}    虚拟化: ${virt}"
  blue "内核: $(uname -r)"
  plain "------------------------------------------------------------"
  plain "拥塞控制: ${cc}"
  plain "可用算法: ${available:-unknown}"
  plain "队列算法: ${qdisc}"
  plain "IPv4 转发: ${ip4_forward:-unknown}"
  plain "IPv6 转发: ${ip6_forward:-unknown}"
  plain "route_localnet: ${route_localnet:-unknown}"
  plain "IPv4 Ping 屏蔽: ${ping4:-unknown}"
  plain "IPv6 Ping 屏蔽: ${ping6:-unknown}"
  plain "------------------------------------------------------------"
  if [[ "${available}" == *"bbrplus"* ]]; then
    green "BBRplus: 当前内核支持"
  else
    yellow "BBRplus: 当前内核未显示支持，安装本仓库内核并重启后再检查"
  fi
}

pause() {
  read -r -p "按回车继续..." _
}

menu() {
  while true; do
    clear || true
    green "============================================================"
    green " sx-ui2 ARM BBRplus / Linux 网络优化工具"
    green "============================================================"
    show_status
    plain ""
    green " 1. 安装 ARM64 BBRplus 内核（本仓库 Release）"
    green " 2. 启用 BBRplus + fq"
    green " 3. 启用 BBR + fq"
    green " 4. TCP 窗口优化（不改当前 BBR/BBRplus 算法）"
    green " 5. 开启 IPv4/IPv6 内核转发"
    green " 6. 系统资源限制优化"
    green " 7. 屏蔽 Ping"
    green " 8. 恢复 Ping"
    green " 9. 查看已安装内核"
    green " 0. 退出"
    plain "------------------------------------------------------------"
    read -r -p "请输入数字: " choice
    case "${choice}" in
      1) install_arm64_bbrplus_kernel; pause ;;
      2) enable_bbrplus; pause ;;
      3) enable_bbr; pause ;;
      4) tcp_window_tune; pause ;;
      5) enable_forwarding; pause ;;
      6) ulimit_tune; pause ;;
      7) ban_ping; pause ;;
      8) unban_ping; pause ;;
      9) show_kernels; pause ;;
      0) exit 0 ;;
      *) warn "输入无效。"; pause ;;
    esac
  done
}

run_command() {
  local cmd="${1:-menu}"
  case "${cmd}" in
    help|-h|--help) usage ;;
    menu) require_root; ensure_dependencies; menu ;;
    install|install-bbrplus|--install-bbrplus) require_root; install_arm64_bbrplus_kernel ;;
    enable-bbrplus|--enable-bbrplus) require_root; enable_bbrplus ;;
    enable-bbr|--enable-bbr) require_root; enable_bbr ;;
    optimize|tcp-tune|--tcp-tune|op0|op1|op2) require_root; tcp_window_tune ;;
    forwarding|--forwarding) require_root; enable_forwarding ;;
    ulimit|--ulimit) require_root; ulimit_tune ;;
    ban-ping|--ban-ping) require_root; ban_ping ;;
    unban-ping|--unban-ping) require_root; unban_ping ;;
    status|--status) show_status ;;
    kernels|--kernels) show_kernels ;;
    *) usage; fail "未知命令: ${cmd}" ;;
  esac
}

run_command "${1:-menu}"
