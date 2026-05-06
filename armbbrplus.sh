#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_SCRIPT_URL="${UPSTREAM_SCRIPT_URL:-https://github.000060000.xyz/tcpx.sh}"
UPSTREAM_SCRIPT_FALLBACK_URL="${UPSTREAM_SCRIPT_FALLBACK_URL:-https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh}"
REPO_SLUG="${REPO_SLUG:-sx-ui2/armbbrplus}"
API_URL="${API_URL:-https://api.github.com/repos/${REPO_SLUG}/releases}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法:
  sudo bash install.sh [原脚本参数]

说明:
  - AMD64: 直接执行原版 tcpx.sh，保留原有全部功能
  - ARM64: 仍然执行原版 tcpx.sh，但在“安装 BBRplus 内核”这一步改用本仓库 release 里的内核包

示例:
  sudo bash install.sh
  sudo bash install.sh op0
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
  ARCH="$(dpkg --print-architecture)"
  VERSION_ID="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  case "${ARCH}" in
    amd64)
      TARGET_KIND="amd64"
      ;;
    arm64)
      TARGET_KIND="arm64"
      ;;
    *)
      red "当前架构是 ${ARCH}，这个脚本目前只支持 amd64 / arm64。"
      exit 1
      ;;
  esac
}

download_upstream_script() {
  local dest="$1"
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${UPSTREAM_SCRIPT_URL}"; then
    yellow "主下载地址不可用，回退到 GitHub 原始地址。"
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${UPSTREAM_SCRIPT_FALLBACK_URL}"
  fi
  chmod +x "${dest}"
}

patch_arm_bbrplus_installer() {
  local script_path="$1"
  python3 - "${script_path}" "${API_URL}" <<'PY'
import re, sys
from pathlib import Path

script_path = Path(sys.argv[1])
api_url = sys.argv[2]
text = script_path.read_text()

override_block = f'''# sx-ui2 armbbrplus override
sxui_find_arm_release_tag() {{
\tlocal suffix="$1"
\tlocal api_url='{api_url}'
\tpython3 -c 'import json,sys,urllib.request
url,suffix=sys.argv[1],sys.argv[2]
req=urllib.request.Request(url, headers={{"Accept":"application/vnd.github+json"}})
with urllib.request.urlopen(req) as resp:
\tdata=json.load(resp)
tags=[item.get("tag_name","") for item in data if item.get("tag_name","").endswith(suffix)]
if not tags:
\traise SystemExit(1)
def norm(tag):
\tcore=tag[:-len(suffix)] if suffix and tag.endswith(suffix) else tag
\tout=[]
\tfor piece in core.split("."):
\t\tout.append(int(piece) if piece.isdigit() else piece)
\treturn out
tags.sort(key=norm, reverse=True)
print(tags[0])' "$api_url" "$suffix"
}}

sxui_download_arm_release_debs() {{
\tlocal release_tag="$1"
\tlocal workdir="$2"
\tlocal api_url='{api_url}'
\tpython3 -c 'import json,os,sys,urllib.request
url,workdir=sys.argv[1],sys.argv[2]
req=urllib.request.Request(url, headers={{"Accept":"application/vnd.github+json"}})
with urllib.request.urlopen(req) as resp:
\tdata=json.load(resp)
assets=[asset for asset in data.get("assets", []) if asset.get("name","").endswith(".deb")]
if not assets:
\tsys.stderr.write("release has no .deb assets\\\\n")
\traise SystemExit(1)
for asset in assets:
\tpath=os.path.join(workdir, asset["name"])
\twith urllib.request.urlopen(asset["browser_download_url"]) as src, open(path, "wb") as dst:
\t\tdst.write(src.read())' "${{api_url}}/tags/${{release_tag}}" "$workdir"
}}

sxui_install_arm_bbrplus_release() {{
\tkernel_version="bbrplus-custom"
\tbit=$(uname -m)
\trm -rf bbrplus
\tmkdir bbrplus && cd bbrplus || exit
\tif [[ "${{OS_type}}" != "Debian" || ( "${{bit}}" != "aarch64" && "${{bit}}" != "arm64" ) ]]; then
\t\techo -e "${{Error}} ARM64 当前只支持 Debian/Ubuntu 使用仓库内核 !" && exit 1
\tfi
\tlocal version_id target_suffix release_tag
\tversion_id="$(. /etc/os-release && echo "${{VERSION_ID:-}}")"
\tcase "$version_id" in
\t\t22.04) target_suffix="-bbrplus" ;;
\t\t24.04) target_suffix="-bbrplus-ubuntu2404" ;;
\t\t*)
\t\t\techo -e "${{Error}} ARM64 当前只支持 Ubuntu 22.04 / 24.04 使用仓库内核 !" && exit 1
\t\t\t;;
\tesac
\trelease_tag="$(sxui_find_arm_release_tag "$target_suffix")" || {{
\t\techo -e "${{Error}} 无法从 sx-ui2/armbbrplus 找到匹配 ARM64 系统的 release !" && exit 1
\t}}
\techo -e "${{Info}} ARM64 BBRplus 将使用 release: $release_tag"
\tsxui_download_arm_release_debs "$release_tag" "$(pwd)" || {{
\t\techo -e "${{Error}} 下载 ARM64 BBRplus release 失败 !" && exit 1
\t}}
\tmapfile -t headers_pkgs < <(find . -maxdepth 1 -type f -name "linux-headers-*.deb" | sort)
\tmapfile -t modules_pkgs < <(find . -maxdepth 1 -type f -name "linux-modules-*.deb" | sort)
\tmapfile -t image_pkgs < <(find . -maxdepth 1 -type f \\( -name "linux-image-*.deb" -o -name "linux-*image*.deb" \\) | sort)
\tmapfile -t extra_pkgs < <(find . -maxdepth 1 -type f \\( -name "linux-libc-dev*.deb" -o -name "linux-tools-*.deb" -o -name "linux-cloud-tools-*.deb" \\) | sort)
\t[[ ${{#image_pkgs[@]}} -gt 0 ]] || {{
\t\techo -e "${{Error}} release 里没有找到 linux-image-*.deb !" && exit 1
\t}}
\tdpkg -i "${{headers_pkgs[@]}}" "${{modules_pkgs[@]}}" "${{image_pkgs[@]}}" "${{extra_pkgs[@]}}"
\tapt-get -f install -y
\tkernel_version="${{release_tag}}"
\tcd .. && rm -rf bbrplus
\tBBR_grub
\techo -e "${{Tip}} 内核安装完毕，请参考上面的信息检查是否安装成功,默认从排第一的高版本内核启动"
\tcheck_kernel
}}

installbbrplus() {{
\tsxui_install_arm_bbrplus_release
}}

installbbrplusnew() {{
\tsxui_install_arm_bbrplus_release
}}

#############系统检测组件#############'''

pattern = re.compile(r'#############系统检测组件#############', re.S)
new_text, count = pattern.subn(override_block, text, count=1)
if count != 1:
    raise SystemExit("failed to inject armbbrplus override block")
script_path.write_text(new_text)
PY
}

main() {
  require_root
  require_cmd curl
  require_cmd dpkg
  detect_target

  local work_dir="" script_path=""
  work_dir="$(mktemp -d /tmp/tcpx-launch.XXXXXX)"
  trap '[[ -n "${work_dir:-}" ]] && rm -rf "${work_dir}"' EXIT
  script_path="${work_dir}/tcpx.sh"

  download_upstream_script "${script_path}"

  if [[ "${TARGET_KIND}" == "arm64" ]]; then
    patch_arm_bbrplus_installer "${script_path}"
  fi

  bash "${script_path}" "$@"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

main "$@"
