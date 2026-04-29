#!/usr/bin/env bash

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# =================================================
#  全局配置区 (Configuration as Data)
# =================================================
readonly SH_VER="100.0.5.8"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master"
readonly GITHUB_API_URL="https://api.github.com/repos/ylx2016/kernel/releases"
readonly SXUI_REPO_SLUG="${SXUI_REPO_SLUG:-sx-ui2/armbbrplus}"
readonly SXUI_GITHUB_API_URL="https://api.github.com/repos/${SXUI_REPO_SLUG}"

# 颜色变量定义
readonly GREEN_FONT_PREFIX="\033[32m"
readonly RED_FONT_PREFIX="\033[31m"
readonly YELLOW_FONT_PREFIX="\033[33m"
readonly FONT_COLOR_SUFFIX="\033[0m"
readonly INFO="${GREEN_FONT_PREFIX}[信息]${FONT_COLOR_SUFFIX}"
readonly ERROR="${RED_FONT_PREFIX}[错误]${FONT_COLOR_SUFFIX}"
readonly TIP="${YELLOW_FONT_PREFIX}[注意]${FONT_COLOR_SUFFIX}"

# 系统信息全局变量 (初始化)
OS_TYPE=""
OS_ID=""
OS_VERSION_ID=""
OS_ARCH=""

# 检查当前用户是否为 root
if [ "$EUID" -ne 0 ]; then
	echo -e "${ERROR} 请使用 root 用户身份运行此脚本"
	exit 1
fi

# =================================================
#  系统检测模块
# =================================================
check_sys() {
	# 1. 检测架构 (使用最通用的 uname)
	OS_ARCH=$(uname -m)

	# 2. 现代化系统信息获取
	if [[ -f /etc/os-release ]]; then
		# 直接 source 解析标准的 os-release 文件
		. /etc/os-release
		OS_ID="${ID:-unknown}"
		OS_VERSION_ID="${VERSION_ID:-}"
		# 兼容 Debian testing/sid 没有 VERSION_ID 的情况
		if [[ -z "$OS_VERSION_ID" && "$OS_ID" == "debian" && -f /etc/debian_version ]]; then
			OS_VERSION_ID=$(grep -oE '^[0-9]+' /etc/debian_version | head -n 1)
			[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID=$(awk -F'/' '{print $1}' /etc/debian_version)
		fi
		[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID="unknown"
	elif [[ -f /etc/redhat-release || -f /etc/centos-release ]]; then
		# 兼容极少数没有 os-release 的老旧 CentOS
		OS_ID="centos"
		OS_VERSION_ID=$(grep -oE '[0-9.]+' /etc/redhat-release | awk -F'.' '{print $1}')
	else
		echo -e "${ERROR} 无法检测到受支持的系统版本。此脚本仅支持现代 Debian/Ubuntu/CentOS/Alma/Rocky 系统。"
		exit 1
	fi

	# 3. 规范化 OS_TYPE (分为 CentOS 系和 Debian 系)
	case "${OS_ID}" in
	centos | rhel | almalinux | rocky | oracle | fedora)
		OS_TYPE="CentOS"
		# 提取主版本号
		OS_VERSION_ID=$(echo "$OS_VERSION_ID" | awk -F'.' '{print $1}')
		;;
	debian | ubuntu | pop)
		OS_TYPE="Debian"
		;;
	*)
		echo -e "${ERROR} 不支持的系统分支: ${OS_ID}"
		exit 1
		;;
	esac

	echo -e "${INFO} 检测到系统: ${OS_TYPE} (${OS_ID} ${OS_VERSION_ID}) - 架构: ${OS_ARCH}"

	# 4. 精简依赖检查 (抛弃笨重的 lsb_release，引入轻量的 jq 用于后续 API 解析)
	local required_cmds=("curl" "wget" "awk" "jq")

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		for cmd in "${required_cmds[@]}"; do
			if ! command -v "$cmd" >/dev/null 2>&1; then
				echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
				if [[ "$cmd" == "jq" ]] && ! rpm -q epel-release >/dev/null 2>&1; then
					yum install -y epel-release >/dev/null 2>&1
				fi
				yum install -y "$cmd" >/dev/null 2>&1
			fi
		done
		# CA 证书更新
		if ! rpm -q ca-certificates >/dev/null 2>&1; then
			yum install ca-certificates -y >/dev/null 2>&1
			update-ca-trust force-enable
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local need_update=0
		for cmd in "${required_cmds[@]}"; do
			if ! command -v "$cmd" >/dev/null 2>&1; then
				if [[ $need_update -eq 0 ]]; then
					apt-get update >/dev/null 2>&1
					need_update=1
				fi
				echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
				apt-get install -y "$cmd" >/dev/null 2>&1
			fi
		done
		# CA 证书更新
		if ! dpkg-query -W ca-certificates >/dev/null 2>&1; then
			[[ $need_update -eq 0 ]] && apt-get update >/dev/null 2>&1
			apt-get install ca-certificates -y >/dev/null 2>&1
			update-ca-certificates >/dev/null 2>&1
		fi
	fi
}

# =================================================
#  网络通信与下载模块
# =================================================

# 全局变量：是否在中国大陆
IS_CN=0

# 1. 极其稳定且快速的 CN 节点检测 (利用 Cloudflare CDN Trace)
check_cn_status() {
	# 设置 3 秒超时，获取 Cloudflare 边缘节点看到的 IP 归属地
	local cf_trace=$(curl -sL --max-time 3 https://www.cloudflare.com/cdn-cgi/trace || echo "")
	if echo "$cf_trace" | grep -q "loc=CN"; then
		IS_CN=1
		echo -e "${INFO} 检测到当前节点位于中国大陆，将自动启用 GitHub 加速镜像。"
	else
		IS_CN=0
		echo -e "${INFO} 当前节点位于海外，使用 GitHub 直连网络。"
	fi
}

# 2. 安全可靠的下载函数 (自带多镜像轮询 failover)
# 用法: safe_wget <下载直链> <保存路径>
safe_wget() {
	local url="$1"
	local dest="$2"
	local timeout=15

	# 定义多个加速镜像前缀 (按稳定性排序)
	local mirrors=(
		"" # 第一个是原生链接，给海外机准备的
		"https://gh-proxy.com/"
		"https://ghfast.top/"
		"https://hub.gitmirror.com/"
		"https://gh.ddlc.top/"
	)

	# 如果不是国内，只保留原生链接（空前缀）
	[[ $IS_CN -eq 0 ]] && mirrors=("")

	for prefix in "${mirrors[@]}"; do
		# 组装最终下载链接
		local target_url="${prefix}${url}"
		[[ -n "$prefix" ]] && target_url="${prefix}$(echo "$url" | sed 's|^https://||')"

		echo -e "${INFO} 正在下载: ${dest} ..."
		# 使用 wget，设置重试 2 次，跳过证书校验
		if wget --no-check-certificate -qT "$timeout" -t 2 -O "$dest" "$target_url"; then
			echo -e "${INFO} 下载成功！"
			return 0
		fi
		[[ $IS_CN -eq 1 ]] && echo -e "${TIP} 镜像节点下载失败，尝试切换下一个节点..."
	done

	echo -e "${ERROR} 文件 ${dest} 所有下载节点均失败，请检查网络或稍后再试！"
	return 1
}

# 3. 稳健的 GitHub 资源获取函数 (使用 jq 提取 JSON)
# 用法: get_github_asset <仓库名> <Tag关键词> <文件名关键词>
# 示例: get_github_asset "ylx2016/kernel" "Debian_Kernel" "headers"
# 3. 稳健的 GitHub 资源获取函数 (提取所有链接后通过 grep 多重过滤)
get_github_asset() {
	local repo="$1"
	local tag_kw="$2"
	local ast_kw="$3"
	local arch_kw="$4" # 可选的架构关键词
	local api_url="https://api.github.com/repos/${repo}/releases"

	local response=$(curl -sL --max-time 10 "$api_url")
	if echo "$response" | grep -q "API rate limit exceeded"; then
		echo -e "${ERROR} 触发 GitHub API 频率限制！(当前 IP 请求过多)" >&2
		return 1
	fi

	# 提取出该仓库所有的下载直链
	local all_urls=$(echo "$response" | jq -r '.[].assets[]?.browser_download_url' 2>/dev/null)
	if [[ -z "$all_urls" ]]; then
		echo -e "${ERROR} 无法从 ${repo} 获取资源列表，请检查网络或稍后再试！" >&2
		return 1
	fi

	# 利用 grep -iE 进行层层精准过滤
	local result=$(echo "$all_urls" | grep -iE "$tag_kw" | grep -iE "$ast_kw")
	[[ -n "$arch_kw" ]] && result=$(echo "$result" | grep -iE "$arch_kw")

	# 终极防呆机制：如果是 x86_64 架构，且关键词中没有声明要找 arm64，则强行排除带 arm64/aarch64 的链接，防止模糊匹配误伤
	if [[ "$arch_kw" != *"arm64"* && "$tag_kw" != *"arm64"* && "$OS_ARCH" != "aarch64" ]]; then
		result=$(echo "$result" | grep -viE "arm64|aarch64")
	fi

	local asset_url=$(echo "$result" | head -n 1)

	if [[ -z "$asset_url" ]]; then
		echo -e "${ERROR} 无法在 ${repo} 中解析到匹配关键字 (${tag_kw} -> ${ast_kw} -> ${arch_kw}) 的文件！" >&2
		return 1
	fi

	echo "$asset_url"
}

# =================================================
#  内核安装核心引擎
# =================================================

# 清理旧的 Headers (精简重构)
remove_old_headers() {
	echo -e "${INFO} 正在清理旧的内核 Headers 防止冲突..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		# 找出不是当前正在运行的 kernel-headers 并卸载
		local current_ker=$(uname -r)
		rpm -qa | grep 'kernel-headers' | grep -v "$current_ker" | xargs -r rpm -e --nodeps >/dev/null 2>&1
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		dpkg -l | grep 'linux-headers' | awk '{print $2}' | grep -v "$(uname -r)" | xargs -r apt-get purge -y >/dev/null 2>&1
		apt-get autoremove -y >/dev/null 2>&1
	fi
}

# 终极内核安装函数
# 用法: install_kernel_generic <内核描述名称> <Headers_URL> <Image_URL>
# 终极内核安装函数
# 用法: install_kernel_generic <内核描述名称> <Headers_URL> <Image_URL>
install_kernel_generic() {
	local kernel_desc="$1"
	local head_url="$2"
	local img_url="$3"

	echo -e "${INFO} ================================================"
	echo -e "${INFO} 开始安装: ${kernel_desc} 内核"
	echo -e "${INFO} ================================================"

	# 只强制检查 img_url，因为某些内核（如 Cloud）本身就没有 Headers
	if [[ -z "$img_url" ]]; then
		echo -e "${ERROR} 传入的镜像文件下载链接为空，可能是 API 解析失败或上游移除了文件！"
		exit 1
	fi

	# 清理旧 headers
	remove_old_headers

	# 创建独立的工作目录
	local work_dir="/tmp/kernel_install_$(date +%s)"
	mkdir -p "$work_dir" && cd "$work_dir" || exit 1

	# 根据系统执行不同的下载和安装逻辑
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local head_file="kernel-headers.rpm"
		local img_file="kernel-image.rpm"

		[[ -n "$head_url" ]] && { safe_wget "$head_url" "$head_file" || exit 1; }
		safe_wget "$img_url" "$img_file" || exit 1

		echo -e "${INFO} 正在执行 YUM 安装..."
		if [[ -n "$head_url" ]]; then
			yum install -y "$img_file" "$head_file"
		else
			yum install -y "$img_file"
		fi

	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local head_file="linux-headers.deb"
		local img_file="linux-image.deb"

		[[ -n "$head_url" ]] && { safe_wget "$head_url" "$head_file" || exit 1; }
		safe_wget "$img_url" "$img_file" || exit 1

		echo -e "${INFO} 正在执行 DPKG 安装..."
		dpkg -i "$img_file"
		[[ -n "$head_url" ]] && dpkg -i "$head_file"
		apt-get install -f -y # 自动修复可能缺失的依赖
	fi

	# 善后清理
	cd /tmp && rm -rf "$work_dir"

	echo -e "${INFO} ${kernel_desc} 内核包安装完成，正在更新系统引导..."
	BBR_grub
}

# 安装 BBR 原版内核 (调用引擎)
installbbr() {
	local head_url=""
	local img_url=""
	local tag_kw="Debian_Kernel"
	local arch_kw="amd64"

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		# CentOS 目前保留你的写死链接逻辑
		head_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_6.1.35_latest_bbr_2023.06.22-0855/kernel-headers-6.1.35-1.x86_64.rpm"
		img_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_6.1.35_latest_bbr_2023.06.22-0855/kernel-6.1.35-1.x86_64.rpm"
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		if [[ "$OS_ARCH" == "aarch64" ]]; then
			tag_kw="Debian_Kernel_arm64"
			arch_kw="arm64"
		fi

		echo -e "${INFO} 正在向 ylx2016/kernel 请求最新 BBR 内核数据..."
		head_url=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "headers" "${arch_kw}")
		# 镜像文件通常不包含 headers 关键字
		img_url=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "image" "${arch_kw}")
	fi

	# 一行代码完成下载、清理、安装、更新引导全流程
	install_kernel_generic "BBR原版内核" "$head_url" "$img_url"
}

# 安装 BBRplus 新版内核 (调用引擎)
# sx-ui2: 从本仓库 Release 安装 ARM64 BBRplus 内核
sxui_find_arm_bbrplus_release_tag() {
	local suffix="$1"
	local api_url="${SXUI_GITHUB_API_URL}/releases?per_page=100"
	local response tag

	response=$(curl -sL --max-time 20 "$api_url") || return 1
	if echo "$response" | grep -q "API rate limit exceeded"; then
		echo -e "${ERROR} GitHub API 频率限制，请稍后再试。" >&2
		return 1
	fi

	tag=$(echo "$response" | jq -r --arg suffix "$suffix" '.[] | select(.draft != true) | .tag_name | select(endswith($suffix))' 2>/dev/null | sort -V | tail -n 1)
	[[ -n "$tag" && "$tag" != "null" ]] || return 1
	echo "$tag"
}

sxui_download_arm_bbrplus_release_debs() {
	local release_tag="$1"
	local work_dir="$2"
	local api_url="${SXUI_GITHUB_API_URL}/releases/tags/${release_tag}"
	local response urls url file_name image_count=0

	response=$(curl -sL --max-time 20 "$api_url") || return 1
	urls=$(echo "$response" | jq -r '.assets[]?.browser_download_url | select(endswith(".deb"))' 2>/dev/null)
	[[ -n "$urls" ]] || {
		echo -e "${ERROR} release ${release_tag} 没有 .deb 资产。" >&2
		return 1
	}

	while IFS= read -r url; do
		[[ -z "$url" ]] && continue
		file_name=$(basename "${url%%\?*}")
		[[ "$file_name" == *linux-image* ]] && image_count=$((image_count + 1))
		safe_wget "$url" "${work_dir}/${file_name}" || return 1
	done <<< "$urls"

	[[ $image_count -gt 0 ]] || {
		echo -e "${ERROR} release ${release_tag} 没有 linux-image 内核包。" >&2
		return 1
	}
}

sxui_install_arm_bbrplus_release() {
	if [[ "${OS_TYPE}" != "Debian" || ( "${OS_ARCH}" != "aarch64" && "${OS_ARCH}" != "arm64" ) ]]; then
		return 1
	fi

	if [[ "${OS_ID}" != "ubuntu" ]]; then
		echo -e "${ERROR} 本仓库 ARM64 BBRplus 内核当前只支持 Ubuntu 22.04 / 24.04。"
		exit 1
	fi

	local suffix=""
	case "${OS_VERSION_ID}" in
		22.04) suffix="-bbrplus" ;;
		24.04) suffix="-bbrplus-ubuntu2404" ;;
		*)
			echo -e "${ERROR} 当前系统是 Ubuntu ${OS_VERSION_ID}，ARM64 BBRplus 只支持 22.04 / 24.04。"
			exit 1
			;;
	esac

	local release_tag
	release_tag=$(sxui_find_arm_bbrplus_release_tag "$suffix") || {
		echo -e "${ERROR} 无法从 ${SXUI_REPO_SLUG} 找到匹配 ${suffix} 的 ARM64 BBRplus release。"
		exit 1
	}

	echo -e "${INFO} ARM64 BBRplus 将使用本仓库 release: ${release_tag}"
	remove_old_headers

	local work_dir="/tmp/sxui_arm_bbrplus_${release_tag}_$(date +%s)"
	mkdir -p "$work_dir" && cd "$work_dir" || exit 1
	sxui_download_arm_bbrplus_release_debs "$release_tag" "$work_dir" || exit 1

	local headers_pkgs=()
	local modules_pkgs=()
	local image_pkgs=()
	local extra_pkgs=()
	mapfile -t headers_pkgs < <(find "$work_dir" -maxdepth 1 -type f -name "linux-headers-*.deb" | sort)
	mapfile -t modules_pkgs < <(find "$work_dir" -maxdepth 1 -type f -name "linux-modules-*.deb" | sort)
	mapfile -t image_pkgs < <(find "$work_dir" -maxdepth 1 -type f \( -name "linux-image-*.deb" -o -name "linux-*image*.deb" \) | sort)
	mapfile -t extra_pkgs < <(find "$work_dir" -maxdepth 1 -type f \( -name "linux-libc-dev*.deb" -o -name "linux-tools-*.deb" -o -name "linux-cloud-tools-*.deb" \) | sort)
	[[ ${#image_pkgs[@]} -gt 0 ]] || {
		echo -e "${ERROR} release ${release_tag} 里没有 linux-image 内核包。"
		exit 1
	}

	echo -e "${INFO} 正在安装 ARM64 BBRplus 内核包..."
	dpkg -i "${headers_pkgs[@]}" "${modules_pkgs[@]}" "${image_pkgs[@]}" "${extra_pkgs[@]}" || apt-get install -f -y
	apt-get install -f -y

	cd /tmp && rm -rf "$work_dir"
	BBR_grub
	echo -e "${TIP} ARM64 BBRplus 内核安装完毕，请重启后检查：uname -r && sysctl net.ipv4.tcp_congestion_control"
	check_kernel
}

installbbrplusnew() {
	if [[ "${OS_TYPE}" == "Debian" && ( "${OS_ARCH}" == "aarch64" || "${OS_ARCH}" == "arm64" ) ]]; then
		sxui_install_arm_bbrplus_release
		return
	fi

	local head_url=""
	local img_url=""
	local tag_kw="bbrplus-6."
	local ext="deb"
	local arch_kw="amd64"

	[[ "${OS_TYPE}" == "CentOS" ]] && ext="rpm"
	[[ "$OS_ARCH" == "aarch64" ]] && arch_kw="arm64"

	echo -e "${INFO} 正在向 UJX6N/bbrplus-6.x_stable 请求数据..."
	head_url=$(get_github_asset "UJX6N/bbrplus-6.x_stable" "${tag_kw}" "headers" "${arch_kw}.*${ext}")
	img_url=$(get_github_asset "UJX6N/bbrplus-6.x_stable" "${tag_kw}" "image" "${arch_kw}.*${ext}")

	install_kernel_generic "BBRplus(UJX6N)新版内核" "$head_url" "$img_url"
}

# 安装 BBRplus 内核 4.14.129 (cx9208版)
installbbrplus() {
	if [[ "${OS_TYPE}" == "Debian" && ( "${OS_ARCH}" == "aarch64" || "${OS_ARCH}" == "arm64" ) ]]; then
		sxui_install_arm_bbrplus_release
		return
	fi

	local head_url=""
	local img_url=""

	if [[ "${OS_TYPE}" == "CentOS" && "${OS_VERSION_ID}" == "7" ]]; then
		head_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/centos/7/kernel-headers-4.14.129-bbrplus.rpm"
		img_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/centos/7/kernel-4.14.129-bbrplus.rpm"
	elif [[ "${OS_TYPE}" == "Debian" && "${OS_ARCH}" == "x86_64" ]]; then
		head_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/debian-ubuntu/x64/linux-headers-4.14.129-bbrplus.deb"
		img_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/debian-ubuntu/x64/linux-image-4.14.129-bbrplus.deb"
	else
		echo -e "${ERROR} BBRplus 4.14.129 仅支持 CentOS 7 或 Debian x86_64！"
		exit 1
	fi

	install_kernel_generic "BBRplus 4.14.129" "$head_url" "$img_url"
}

# 安装 Xanmod 自编译老版本
installxanmod() {
	echo -e "${TIP} Xanmod 这个自编译版本不维护了，后续请用官方编译版本，知悉。"
	local head_url=""
	local img_url=""

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		if [[ "${OS_VERSION_ID}" == "7" ]]; then
			head_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_5.15.95-xanmod1_lts_latest_2023.02.24-2159/kernel-headers-5.15.95_xanmod1-1.x86_64.rpm"
			img_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_5.15.95-xanmod1_lts_latest_2023.02.24-2159/kernel-5.15.95_xanmod1-1.x86_64.rpm"
		elif [[ "${OS_VERSION_ID}" == "8" ]]; then
			head_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_5.15.81-xanmod1_lts_C8_latest_2022.12.06-1614/kernel-headers-5.15.81_xanmod1-1.x86_64.rpm"
			img_url="https://github.com/ylx2016/kernel/releases/download/Centos_Kernel_5.15.81-xanmod1_lts_C8_latest_2022.12.06-1614/kernel-5.15.81_xanmod1-1.x86_64.rpm"
		fi
	elif [[ "${OS_TYPE}" == "Debian" && "${OS_ARCH}" == "x86_64" ]]; then
		head_url="https://github.com/ylx2016/kernel/releases/download/Debian_Kernel_5.15.95-xanmod1_lts_latest_2023.02.24-2210/linux-headers-5.15.95-xanmod1_5.15.95-xanmod1-1_amd64.deb"
		img_url="https://github.com/ylx2016/kernel/releases/download/Debian_Kernel_5.15.95-xanmod1_lts_latest_2023.02.24-2210/linux-image-5.15.95-xanmod1_5.15.95-xanmod1-1_amd64.deb"
	else
		echo -e "${ERROR} 当前架构或系统不支持该 Xanmod 版本！"
		exit 1
	fi

	install_kernel_generic "Xanmod 自编译版" "$head_url" "$img_url"
}

# 安装官方 Cloud 内核
installcloud() {
	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} Cloud 内核仅支持 Debian 系系统"
		exit 1
	}

	local img_url_base
	local img_pattern
	if [[ "$OS_ARCH" == "x86_64" ]]; then
		img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/"
		img_pattern='linux-image-[^"]+cloud-amd64_[^"]+_amd64\.deb'
	elif [[ "$OS_ARCH" == "aarch64" ]]; then
		img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-arm64/"
		img_pattern='linux-image-[^"]+cloud-arm64_[^"]+_arm64\.deb'
	else
		echo -e "${ERROR} 不支持的架构：$OS_ARCH"
		exit 1
	fi

	echo -e "${INFO} 正在从 Debian 官方源获取 Cloud 内核列表..."
	local deb_files=$(curl -sL --max-time 10 "$img_url_base" | grep -oE "$img_pattern" | sort -V | uniq)

	if [[ -z "$deb_files" ]]; then
		echo -e "${ERROR} 未找到可用的 Cloud 内核版本，请检查网络！"
		exit 1
	fi

	# 将文件列表转换为数组
	mapfile -t versions_array <<<"$deb_files"

	echo -e "${INFO} 检测到以下 Cloud 内核版本："
	for i in "${!versions_array[@]}"; do
		# 截取版本号用于展示
		local v_show=$(echo "${versions_array[$i]}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')
		echo "  $i) [$v_show] -> ${versions_array[$i]}"
	done

	local default_idx=$((${#versions_array[@]} - 1))
	echo -e "${TIP} 请选择要安装的内核版本（10秒后默认选择最新版本，输入 'h' 则使用 apt 安装）："
	read -t 10 -p "输入选项 [0-$default_idx 或 h]: " choice

	if [[ "$choice" =~ ^[hH]$ ]]; then
		echo -e "${INFO} 正在使用 apt 安装 Cloud 内核及 Headers..."
		apt-get update >/dev/null 2>&1
		local arch_ext="amd64"
		[[ "$OS_ARCH" == "aarch64" ]] && arch_ext="arm64"
		apt-get install -y "linux-image-cloud-${arch_ext}" "linux-headers-cloud-${arch_ext}"
		BBR_grub
		return 0
	fi

	choice=${choice:-$default_idx}
	if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "$default_idx" ]; then
		echo -e "${TIP} 无效选项，默认安装最新版本..."
		choice=$default_idx
	fi

	local selected_file="${versions_array[$choice]}"
	# 传递给通用引擎（此处无 Headers，留空）
	install_kernel_generic "Debian 官方 Cloud" "" "${img_url_base}${selected_file}"
}

# 安装 Lotserver (锐速) 专属内核
installlot() {
	[[ "$OS_ARCH" != "x86_64" ]] && {
		echo -e "${ERROR} Lotserver 仅支持 x86_64 架构！"
		exit 1
	}

	remove_old_headers

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local lot_ver="4.11.2-1" # CentOS 7 默认
		[[ "${OS_VERSION_ID}" == "6" ]] && lot_ver="2.6.32-504"

		local base_url="http://${GITHUB_RAW_URL}/lotserver/centos/${OS_VERSION_ID}/x64"

		rpm --import "http://${GITHUB_RAW_URL}/lotserver/centos/RPM-GPG-KEY-elrepo.org" >/dev/null 2>&1
		yum remove -y kernel-firmware kernel-headers >/dev/null 2>&1

		# 使用 safe_wget 增强下载稳定性
		local work_dir="/tmp/lot_install"
		mkdir -p "$work_dir" && cd "$work_dir"

		safe_wget "${base_url}/kernel-firmware-${lot_ver}.rpm" "kernel-firmware.rpm"
		safe_wget "${base_url}/kernel-${lot_ver}.rpm" "kernel.rpm"
		safe_wget "${base_url}/kernel-headers-${lot_ver}.rpm" "kernel-headers.rpm"
		safe_wget "${base_url}/kernel-devel-${lot_ver}.rpm" "kernel-devel.rpm"

		echo -e "${INFO} 正在安装 Lotserver 专属内核组件..."
		yum install -y *.rpm
		cd /tmp && rm -rf "$work_dir"

	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		# Debian/Ubuntu 走老旧的 snapshot.debian.org 源
		apt-get autoremove -y >/dev/null 2>&1
		local work_dir="/tmp/lot_install"
		mkdir -p "$work_dir" && cd "$work_dir"

		if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "8" ]]; then
			safe_wget "http://snapshot.debian.org/archive/debian/20120304T220938Z/pool/main/l/linux-base/linux-base_3.5_all.deb" "linux-base.deb"
			safe_wget "http://snapshot.debian.org/archive/debian/20171008T163152Z/pool/main/l/linux/linux-image-3.16.0-4-amd64_3.16.43-2+deb8u5_amd64.deb" "linux-image.deb"
		elif [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "9" ]]; then
			safe_wget "http://snapshot.debian.org/archive/debian/20160917T042239Z/pool/main/l/linux-base/linux-base_4.5_all.deb" "linux-base.deb"
			safe_wget "http://snapshot.debian.org/archive/debian/20171224T175424Z/pool/main/l/linux/linux-image-4.9.0-4-amd64_4.9.65-3+deb9u1_amd64.deb" "linux-image.deb"
		else
			echo -e "${ERROR} Lotserver 不支持当前系统版本！"
			exit 1
		fi

		dpkg -l | grep -q 'linux-base' || dpkg -i linux-base.deb
		dpkg -i linux-image.deb
		apt-get install -f -y
		cd /tmp && rm -rf "$work_dir"
	fi

	echo -e "${INFO} Lotserver 内核包安装完成，正在更新系统引导..."
	BBR_grub
}

# =================================================
#  系统级网络与资源自适应优化 (替换旧版优化)
# =================================================
optimizing_system() {
	echo -e "${INFO} 开始进行系统级网络优化 (自适应 CPU/内存/内核版本)..."

	# 1. 动态获取系统硬件与内核参数
	local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	local total_mem_mb=$((total_mem_kb / 1024))
	local cpu_cores=$(nproc)
	local kernel_major=$(uname -r | cut -d. -f1)
	local kernel_minor=$(uname -r | cut -d. -f2)

	# 新增：动态获取当前正在使用的拥塞控制算法，防止覆盖 LotSpeed 或其它自定义算法
	local current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "bbr")
	local current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")
	[[ "$current_cc" == "unknown" || -z "$current_cc" ]] && current_cc="bbr"
	[[ "$current_qdisc" == "unknown" || -z "$current_qdisc" ]] && current_qdisc="fq"

	# 2. 根据内存大小动态适配网络缓存与文件描述符
	local tcp_mem_max somaxconn file_max
	if [ "$total_mem_mb" -ge 8192 ]; then
		# 8GB 及以上高配机器
		tcp_mem_max=134217728 # 128MB 缓存
		somaxconn=1048576
		file_max=2097152
	elif [ "$total_mem_mb" -ge 2048 ]; then
		# 2GB - 8GB 中等配置
		tcp_mem_max=67108864 # 64MB 缓存
		somaxconn=65535
		file_max=1048576
	else
		# 2GB 以下小内存机器
		tcp_mem_max=16777216 # 16MB 缓存
		somaxconn=32768
		file_max=524288
	fi

	# 3. 根据 CPU 核心数动态适配网卡队列与积压
	local netdev_max_backlog=$((10000 * cpu_cores))
	[[ $netdev_max_backlog -lt 32768 ]] && netdev_max_backlog=32768
	[[ $netdev_max_backlog -gt 100000 ]] && netdev_max_backlog=100000

	local netdev_budget=$((300 + 20 * cpu_cores))
	[[ $netdev_budget -gt 50000 ]] && netdev_budget=50000

	# 4. 生成统一的 sysctl 配置文件
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"

	# 备份并清空原文件（比几十行 sed -i 速度快且更安全）
	[[ -f "$sysctl_conf" ]] && cp "$sysctl_conf" "${sysctl_conf}.bak"
	cat /dev/null >"$sysctl_conf"

	# 写入基础通用优化 (兼容 CentOS 7-9, Debian 9-12, Ubuntu 18-24)
	cat >>"$sysctl_conf" <<EOF
# --- 文件系统与内存基础 ---
fs.file-max = $file_max
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = $file_max
kernel.pid_max = 65535
vm.swappiness = 1
vm.overcommit_memory = 1

# --- 网络核心队列与连接数 ---
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.netdev_budget = $netdev_budget
net.core.rmem_max = $tcp_mem_max
net.core.wmem_max = $tcp_mem_max
net.core.rmem_default = $((tcp_mem_max / 2))
net.core.wmem_default = $((tcp_mem_max / 2))
net.core.optmem_max = 65536

# --- TCP 核心调优 (缓冲区自适应) ---
net.ipv4.tcp_rmem = 4096 87380 $tcp_mem_max
net.ipv4.tcp_wmem = 4096 65536 $tcp_mem_max
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_frto = 0

# --- TCP 超时、重传与 KeepAlive 优化 ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3

# --- 路由转发与 IPv6 (默认开启转发以兼容 Docker/Tailscale 等) ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# --- 默认拥塞控制 (动态继承) ---
net.core.default_qdisc = $current_qdisc
net.ipv4.tcp_congestion_control = $current_cc
EOF

	# 5. 根据内核版本进行高级参数兼容
	# 移除低版本废弃参数: net.ipv4.tcp_tw_recycle (在内核 4.12 中已彻底移除，高版本强制写入会报错)
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 12) ]]; then
		echo "net.ipv4.tcp_tw_recycle = 0" >>"$sysctl_conf"
	fi

	# 移除低版本废弃参数: net.ipv4.tcp_fack (在内核 4.11 中已废弃，合并到了通用重传逻辑中)
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 11) ]]; then
		echo "net.ipv4.tcp_fack = 1" >>"$sysctl_conf"
	fi

	# 6. 系统资源限制极限优化 (systemd 与 limits.conf)
	echo -e "${INFO} 正在根据内存大小自动优化系统文件描述符限制..."

	# 优化 Systemd 配置
	if [[ -d "/etc/systemd" ]]; then
		cat >/etc/systemd/system.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=$file_max
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF
		systemctl daemon-reload >/dev/null 2>&1
	fi

	# 优化 limits.conf
	cat >/etc/security/limits.conf <<EOF
* soft   nofile    $file_max
* hard   nofile    $file_max
* soft   nproc     unlimited
* hard   nproc     unlimited
* soft   core      unlimited
* hard   core      unlimited
root  soft   nofile    $file_max
root  hard   nofile    $file_max
root  soft   nproc     unlimited
root  hard   nproc     unlimited
root  soft   core      unlimited
root  hard   core      unlimited
EOF

	# 清理旧的 ulimit 注入
	sed -i '/ulimit -SHn/d' /etc/profile
	sed -i '/ulimit -SHu/d' /etc/profile
	echo "ulimit -SHn $file_max" >>/etc/profile

	# 修复 Pam 会话限制
	if [[ -f "/etc/pam.d/common-session" ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
		echo "session required pam_limits.so" >>/etc/pam.d/common-session
	fi

	# 7. 应用内核与系统参数
	echo -e "${INFO} 正在应用自适应内核配置..."
	sysctl -p "$sysctl_conf" >/dev/null 2>&1
	sysctl --system >/dev/null 2>&1

	# 启用透明大页加速 (如果支持)
	if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
		echo always >/sys/kernel/mm/transparent_hugepage/enabled
	fi

	echo -e "${INFO} 系统网络与资源限制自适应优化完成！(建议完成后重启服务器以全面生效)"
}

# =================================================
#  网络加速统一切换引擎 (替代原来十几个 startxxx 函数)
# =================================================

# 卸载加速器 (清理配置)
remove_bbr_lotserver() {
	echo -e "${INFO} 正在清理旧的拥塞控制与队列算法配置..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ -f "$sysctl_conf" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net.ipv4.tcp_ecn/d' "$sysctl_conf"
	[[ -f "/etc/sysctl.conf" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net.ipv4.tcp_ecn/d' /etc/sysctl.conf

	sysctl --system >/dev/null 2>&1
	rm -rf bbrmod

	# 修改：停用并卸载 LotSpeed 模块 (但不物理删除文件，以便随时通过菜单快速切换)
	if command -v lotspeed >/dev/null 2>&1; then
		lotspeed stop >/dev/null 2>&1
		rmmod lotspeed >/dev/null 2>&1
	fi
	# 如果没有 helper 脚本但也加载了模块的兜底清理
	if lsmod | grep -q "lotspeed"; then
		rmmod lotspeed >/dev/null 2>&1
	fi

	if [[ -e /appex/bin/lotServer.sh ]]; then
		echo | bash <(wget -qO- https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh) uninstall >/dev/null 2>&1
	fi
}

# 统一加速开启函数
# 用法: enable_acceleration <队列算法> <拥塞控制算法>
enable_acceleration() {
	local qdisc="$1"
	local cc="$2"

	remove_bbr_lotserver

	echo -e "${INFO} 正在应用: ${cc} + ${qdisc} ..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	echo "net.core.default_qdisc=$qdisc" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=$cc" >>"$sysctl_conf"

	sysctl --system >/dev/null 2>&1
	echo -e "${INFO} 加速算法修改成功！如果未立即生效，请重启服务器。"
}

# 启用 Lotserver
startlotserver() {
	remove_bbr_lotserver
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		yum install ethtool -y
	else
		apt-get update && apt-get install ethtool -y
	fi
	echo | bash <(wget --no-check-certificate -qO- https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh) install
	sed -i '/advinacc/d; /maxmode/d' /appex/etc/config
	echo -e "advinacc=\"1\"\nmaxmode=\"1\"" >>/appex/etc/config
	/appex/bin/lotServer.sh restart
	start_menu
}

# 开启/关闭 ECN (显式控制)
set_ecn() {
	local status="$1"
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	sed -i '/net.ipv4.tcp_ecn/d' "$sysctl_conf" /etc/sysctl.conf 2>/dev/null
	echo "net.ipv4.tcp_ecn=$status" >>"$sysctl_conf"
	sysctl --system >/dev/null 2>&1
	[[ "$status" == "1" ]] && echo -e "${INFO} ECN 已开启！" || echo -e "${INFO} ECN 已关闭！"
}

# 彻底卸载全部加速与优化 (抛弃几十个 sed 删除，直接清空文件)
remove_all() {
	echo -e "${INFO} 正在清空网络优化与系统限制..."
	rm -f /etc/sysctl.d/99-sysctl.conf
	cat /dev/null >/etc/sysctl.conf
	sysctl --system >/dev/null 2>&1

	sed -i '/DefaultTimeoutStopSec/d; /DefaultLimitCORE/d; /DefaultLimitNOFILE/d; /DefaultLimitNPROC/d' /etc/systemd/system.conf
	sed -i '/soft   nofile/d; /hard   nofile/d; /soft   nproc/d; /hard   nproc/d; /soft   core/d; /hard   core/d' /etc/security/limits.conf
	sed -i '/ulimit -SHn/d' /etc/profile
	sed -i '/required pam_limits.so/d' /etc/pam.d/common-session

	systemctl daemon-reload
	remove_bbr_lotserver
	# 新增：彻底卸载时，物理清理 LotSpeed 残留文件
	rm -f /usr/local/bin/lotspeed
	rm -rf /opt/lotspeed
	echo -e "${INFO} 系统已恢复原生状态。"
}

# =================================================
#  系统引导与内核管理引擎
# =================================================

# 现代化更新引导 (GRUB)
BBR_grub() {
	echo -e "${INFO} 正在更新系统引导..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		# 现代 CentOS 优先使用 grubby 设置最新内核为默认
		if command -v grubby >/dev/null 2>&1; then
			local latest_kernel=$(grubby --info=ALL | awk -F= '/^kernel/{print $2}' | head -n 1)
			[[ -n "$latest_kernel" ]] && grubby --set-default="$latest_kernel" >/dev/null 2>&1
		else
			[[ -f /boot/grub2/grub.cfg ]] && grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
			grub2-set-default 0
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		if command -v update-grub >/dev/null 2>&1; then
			update-grub >/dev/null 2>&1
		else
			apt-get install -y grub2-common >/dev/null 2>&1
			update-grub >/dev/null 2>&1
		fi
	fi
}

# 查看已安装的内核与排序
show_kernels() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 当前系统中已安装的内核包："
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		rpm -qa | grep -E "^kernel-(image|core|modules|devel|headers)" | sort -V
		echo -e "${INFO} ==================================================="
		echo -e "${INFO} GRUB 引导项 (通常 index=0 为默认启动项)："
		grubby --info=ALL | grep -E "^kernel|^index"
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		dpkg -l | grep -E "^ii  linux-(image|headers|modules)" | awk '{print $2, $3}' | column -t | sort -V
		echo -e "${INFO} ==================================================="
		echo -e "${INFO} /boot 目录下的内核镜像："
		ls -1v /boot/vmlinuz-* 2>/dev/null
	fi
	echo -e "${INFO} ==================================================="
	echo -e "${TIP} 当前实际正在运行的内核: ${GREEN_FONT_PREFIX}$(uname -r)${FONT_COLOR_SUFFIX}"
	echo ""
	read -p "按回车键返回主菜单..."
	start_menu
}

# 高级交互式内核管理 (精准多选删除，支持删除当前内核)
delete_kernel_custom() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 正在扫描系统中已安装的内核包..."
	local current_kernel=$(uname -r)
	local kernel_list=()

	# 使用更精准的包查询方式，防止名字过长被截断
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		mapfile -t kernel_list < <(rpm -qa | grep -E "^kernel-(image|core|modules|devel|headers)" | sort -V)
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		mapfile -t kernel_list < <(dpkg-query -W -f='${Package}\n' | grep -E "^linux-(image|headers|modules)" | sort -V)
	fi

	if [[ ${#kernel_list[@]} -eq 0 ]]; then
		echo -e "${ERROR} 未检测到可管理的内核包。"
		sleep 2
		start_menu
		return
	fi

	echo -e "${TIP} 当前正在运行的内核: ${GREEN_FONT_PREFIX}${current_kernel}${FONT_COLOR_SUFFIX}"
	echo -e "${INFO} ==================================================="

	# 打印带编号的内核列表
	for i in "${!kernel_list[@]}"; do
		local pkg="${kernel_list[$i]}"
		if [[ "$pkg" == *"$current_kernel"* ]]; then
			echo -e "  ${GREEN_FONT_PREFIX}[$i] ${pkg} [*当前运行中*]${FONT_COLOR_SUFFIX}"
		else
			echo -e "  [$i] ${pkg}"
		fi
	done
	echo -e "${INFO} ==================================================="
	echo -e "${TIP} 提示: 排序后默认从最高版本内核启动！"
	echo ""
	read -p "请输入要【删除】的内核编号 (多选请用空格分隔，例如 '0 2 3'，直接回车取消): " del_choices

	if [[ -z "$del_choices" ]]; then
		echo -e "${INFO} 已取消操作，返回主菜单。"
		sleep 2
		start_menu
		return
	fi

	# 遍历用户输入，提取包名
	local pkgs_to_del=""
	local is_del_current=0
	for idx in $del_choices; do
		if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#kernel_list[@]} ]]; then
			local selected_pkg="${kernel_list[$idx]}"
			pkgs_to_del="$pkgs_to_del $selected_pkg"
			# 标记是否包含当前内核
			if [[ "$selected_pkg" == *"$current_kernel"* ]]; then
				is_del_current=1
			fi
		else
			echo -e "${TIP} 无效的编号: $idx，已忽略。"
		fi
	done

	if [[ -z "$pkgs_to_del" ]]; then
		echo -e "${INFO} 没有选择有效的内核，操作结束。"
		sleep 2
		start_menu
		return
	fi

	echo -e "${TIP} 即将从系统中彻底卸载以下内核包:"
	echo -e "${RED_FONT_PREFIX}${pkgs_to_del}${FONT_COLOR_SUFFIX}"

	# 强力警告与二次确认机制
	if [[ $is_del_current -eq 1 ]]; then
		echo -e ""
		echo -e "${ERROR} 高危警告！您选择了删除【当前正在运行的内核】！"
		echo -e "${TIP} 卸载当前运行中的内核，可能会导致您的 SSH 连接中断。"
		echo -e "${TIP} 请务必确保系统中还有【至少一个其他已正常安装的内核】，否则重启后机器将变砖失联！"
		read -p "您确定要继续删除选中的内核包吗？(请输入大写的 YES 确认): " confirm_danger
		if [[ "$confirm_danger" != "YES" ]]; then
			echo -e "${INFO} 操作已取消，出于安全考虑未执行删除。"
			sleep 2
			start_menu
			return
		fi
	else
		read -p "请确认是否卸载？(Y/n): " confirm
		if [[ "$confirm" =~ ^[nN]$ ]]; then
			echo -e "${INFO} 操作已取消。"
			sleep 2
			start_menu
			return
		fi
	fi

	echo -e "${INFO} 正在执行卸载，如果遇到断开连接请不要惊慌，稍等几分钟后尝试重启服务器..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		rpm -e --nodeps $pkgs_to_del
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt-get purge -y $pkgs_to_del
		apt-get autoremove -y >/dev/null 2>&1
	fi

	BBR_grub
	echo -e "${INFO} 指定内核卸载完毕！引导项已自动更新。"
	sleep 2
	start_menu
}

# 编译安装 brutal
startbrutal() {
	if [[ "$headers_status" == "已匹配" ]]; then
		echo -e "${INFO} Headers 已匹配，开始编译 Brutal..."
		bash <(curl -fsSL https://tcp.hy2.sh/)
		if lsmod | grep -q "brutal"; then
			echo -e "${INFO} Brutal 模块已成功加载！"
		else
			echo -e "${ERROR} Brutal 模块未加载，编译可能失败。"
		fi
	else
		echo -e "${ERROR} 当前内核 Headers 不匹配或者未安装，无法编译。"
	fi
}

# 安装启用 LotSpeed (uk0开发)
install_lotspeed() {
	echo -e "${INFO} 准备安装并启用 LotSpeed (ml-tcp 分支) ..."
	# 执行官方一键安装脚本
	bash <(curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/ml-tcp/install.sh)

	if lsmod | grep -q "lotspeed"; then
		echo -e "${INFO} LotSpeed 模块已成功加载！"
		# 将其写入 99-sysctl.conf 确保重启后也是默认算法
		local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
		sed -i '/net.ipv4.tcp_congestion_control/d' "$sysctl_conf" /etc/sysctl.conf 2>/dev/null
		echo "net.ipv4.tcp_congestion_control=lotspeed" >>"$sysctl_conf"
		sysctl --system >/dev/null 2>&1
		echo -e "${INFO} LotSpeed 已设置为默认拥塞控制算法！"
	else
		echo -e "${ERROR} LotSpeed 模块加载失败，请检查上方编译日志（通常是因为内核 Headers 缺失或版本过低）。"
	fi
}

# 单独启用 LotSpeed 加速 (免编译快速切换)
enable_lotspeed_standalone() {
	if ! command -v lotspeed >/dev/null 2>&1; then
		echo -e "${ERROR} 未检测到 LotSpeed，请先执行菜单 [29] 进行编译安装！"
		sleep 3
		return
	fi
	remove_bbr_lotserver
	echo -e "${INFO} 正在启动 LotSpeed 加速..."
	lotspeed start >/dev/null 2>&1

	# 确保将其写死为默认启动项
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	sed -i '/net.ipv4.tcp_congestion_control/d; /net.core.default_qdisc/d' "$sysctl_conf" /etc/sysctl.conf 2>/dev/null
	echo "net.core.default_qdisc=fq" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=lotspeed" >>"$sysctl_conf"
	sysctl --system >/dev/null 2>&1

	echo -e "${INFO} LotSpeed 加速已成功切换并启用！"
}

# =================================================
#  杂项与附加功能模块 (补齐缺失的函数)
# =================================================
Update_Shell() {
	echo -e "${INFO} 正在从 ${SXUI_REPO_SLUG} 更新当前脚本..."
	local self_path update_url tmp_file
	self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
	[[ "$self_path" == /dev/fd/* || "$self_path" == bash || -z "$self_path" ]] && self_path="./armbbrplus.sh"
	update_url="https://raw.githubusercontent.com/${SXUI_REPO_SLUG}/main/armbbrplus.sh"
	tmp_file="${self_path}.new"
	safe_wget "$update_url" "$tmp_file" || exit 1
	mv -f "$tmp_file" "$self_path"
	chmod +x "$self_path"
	echo -e "${INFO} 更新完成，重新启动脚本。"
	exec "$self_path"
	exit 0
}

gototcp() {
	echo -e "${INFO} 正在切换到卸载内核版本..."
	wget -O tcp.sh "https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
	exit 0
}

gotodd() {
	echo -e "${INFO} 正在切换到一键 DD 系统脚本..."
	wget -qO- "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" | bash
	exit 0
}

gotoipcheck() {
	echo -e "${INFO} 正在下载并运行流媒体/IP检测脚本..."
	bash <(curl -L -s check.unlock.media)
	exit 0
}

closeipv6() {
	echo -e "${INFO} 正在禁用 IPv6..."
	sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf 2>/dev/null
	echo "net.ipv6.conf.all.disable_ipv6 = 1" >>/etc/sysctl.d/99-sysctl.conf
	echo "net.ipv6.conf.default.disable_ipv6 = 1" >>/etc/sysctl.d/99-sysctl.conf
	sysctl --system >/dev/null 2>&1
	echo -e "${INFO} IPv6 已成功禁用！"
}

openipv6() {
	echo -e "${INFO} 正在开启 IPv6..."
	sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf 2>/dev/null
	echo "net.ipv6.conf.all.disable_ipv6 = 0" >>/etc/sysctl.d/99-sysctl.conf
	echo "net.ipv6.conf.default.disable_ipv6 = 0" >>/etc/sysctl.d/99-sysctl.conf
	sysctl --system >/dev/null 2>&1
	echo -e "${INFO} IPv6 已成功开启！"
}

optimizing_ddcc() {
	echo -e "${INFO} 正在应用防 CC/DDOS 轻量优化..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	sed -i '/net.ipv4.tcp_syncookies/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv4.tcp_synack_retries/d' "$sysctl_conf" 2>/dev/null
	cat >>"$sysctl_conf" <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024000
net.ipv4.tcp_synack_retries = 1
EOF
	sysctl --system >/dev/null 2>&1
	echo -e "${INFO} 防 CC 基础参数已写入并生效！"
}


# =================================================
#  sx-ui2 额外 Linux 网络优化工具
# =================================================
sxui_apply_sysctl_file() {
	local file="$1"
	sysctl -p "$file" >/dev/null 2>&1 || true
	sysctl --system >/dev/null 2>&1 || true
}

sxui_write_sysctl_file() {
	local file="$1"
	local content="$2"
	mkdir -p /etc/sysctl.d
	cat >"$file" <<EOF
${content}
EOF
	sxui_apply_sysctl_file "$file"
}

sxui_current_cc() {
	sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo bbr
}

sxui_current_qdisc() {
	sysctl -n net.core.default_qdisc 2>/dev/null || echo fq
}

sxui_tcp_window_tune() {
	local cc qdisc
	cc=$(sxui_current_cc)
	qdisc=$(sxui_current_qdisc)
	[[ -z "$cc" || "$cc" == "unknown" ]] && cc="bbr"
	[[ -z "$qdisc" || "$qdisc" == "unknown" ]] && qdisc="fq"

	sxui_write_sysctl_file /etc/sysctl.d/99-sxui-tcp-window.conf "net.ipv4.tcp_no_metrics_save = 1
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
	echo -e "${INFO} TCP 窗口优化已应用，保留当前拥塞控制: ${cc}，队列算法: ${qdisc}。"
}

sxui_enable_forwarding() {
	sxui_write_sysctl_file /etc/sysctl.d/99-sxui-forwarding.conf "net.ipv4.conf.all.route_localnet = 1
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
	echo -e "${INFO} IPv4/IPv6 内核转发已开启。"
	echo -e "${TIP} 这里只开启内核转发；NAT/端口转发仍需单独配置 nftables/iptables 规则。"
}

sxui_ban_ping() {
	sxui_write_sysctl_file /etc/sysctl.d/99-sxui-icmp.conf "net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.icmp.echo_ignore_all = 1"
	echo -e "${INFO} 已尝试屏蔽 IPv4/IPv6 Ping。"
}

sxui_unban_ping() {
	sxui_write_sysctl_file /etc/sysctl.d/99-sxui-icmp.conf "net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 0
net.ipv6.icmp.echo_ignore_all = 0"
	echo -e "${INFO} 已尝试恢复 IPv4/IPv6 Ping。"
}

sxui_ulimit_tune() {
	mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/profile.d
	sxui_write_sysctl_file /etc/sysctl.d/99-sxui-filelimit.conf "fs.file-max = 1000000
fs.nr_open = 1000000"

	cat >/etc/security/limits.d/99-sxui-network-tools.conf <<EOF
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
		echo 'session required pam_limits.so' >>/etc/pam.d/common-session
	fi

	cat >/etc/systemd/system.conf.d/99-sxui-network-tools.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=1000000
DefaultLimitNPROC=1000000
EOF
	ulimit -SHn 1000000 2>/dev/null || true
	ulimit -c unlimited 2>/dev/null || true
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reexec >/dev/null 2>&1 || true
	echo -e "${INFO} 系统资源限制优化已写入。新登录会话和新启动的 systemd 服务会使用新限制。"
}

sxui_network_tools_menu() {
	clear
	echo && echo -e " Linux 网络优化工具 ${RED_FONT_PREFIX}(sx-ui2 内置)${FONT_COLOR_SUFFIX}
 ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} TCP 窗口优化（保留当前 BBR/BBRplus）
 ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 开启 IPv4/IPv6 内核转发
 ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 系统资源限制优化
 ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 屏蔽 Ping
 ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 恢复 Ping
 ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 返回主菜单
————————————————————————————————————————————————————————————————"
	read -p " 请输入数字 :" sxui_num
	case "$sxui_num" in
	1) sxui_tcp_window_tune ;;
	2) sxui_enable_forwarding ;;
	3) sxui_ulimit_tune ;;
	4) sxui_ban_ping ;;
	5) sxui_unban_ping ;;
	0) start_menu ;;
	*) echo -e "${ERROR}: 请输入正确数字" ; sleep 2s ; sxui_network_tools_menu ;;
	esac
	echo -e "${TIP} 操作完成。"
	sleep 2s
	start_menu
}

# =================================================
#  UI 面板与主逻辑
# =================================================

# 获取系统面板信息
get_system_info() {
	opsy="${OS_TYPE} ${OS_VERSION_ID}"
	arch="${OS_ARCH}"
	kern=$(uname -r)

	# 获取虚拟化类型
	if command -v virt-what >/dev/null 2>&1; then
		virtual=$(virt-what | head -n 1)
	elif command -v systemd-detect-virt >/dev/null 2>&1; then
		virtual=$(systemd-detect-virt)
	else
		virtual="Unknown"
	fi
	[[ -z "$virtual" ]] && virtual="Dedicated"
}

# 开始菜单
start_menu() {
	clear
	echo && echo -e " TCP加速 一键安装管理脚本 ${RED_FONT_PREFIX}[v${SH_VER}] 不卸内核${FONT_COLOR_SUFFIX} from blog.ylx.me 母鸡慎用
 ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 升级脚本
 ${GREEN_FONT_PREFIX}91.${FONT_COLOR_SUFFIX} 切换到卸载内核版本
 ———————————————————————————— 内核安装 —————————————————————————————
 ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 安装 BBR原版内核         ${GREEN_FONT_PREFIX}7.${FONT_COLOR_SUFFIX} 安装 官方稳定内核
 ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 安装 BBRplus版内核       ${GREEN_FONT_PREFIX}8.${FONT_COLOR_SUFFIX} 安装 官方最新内核
 ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 安装 Lotserver(锐速)内核 ${GREEN_FONT_PREFIX}9.${FONT_COLOR_SUFFIX} 安装 XANMOD(main)
 ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 安装 官方cloud内核       ${GREEN_FONT_PREFIX}10.${FONT_COLOR_SUFFIX} 安装 XANMOD(LTS)
 ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 安装 BBRplus新版内核     ${GREEN_FONT_PREFIX}11.${FONT_COLOR_SUFFIX} 安装 XANMOD(EDGE)
 ${GREEN_FONT_PREFIX}6.${FONT_COLOR_SUFFIX} 安装 Zen官方版内核       ${GREEN_FONT_PREFIX}12.${FONT_COLOR_SUFFIX} 安装 XANMOD(RT)
 ———————————————————————————— 加速启用 —————————————————————————————
 ${GREEN_FONT_PREFIX}20.${FONT_COLOR_SUFFIX} 使用BBR+FQ加速          ${GREEN_FONT_PREFIX}21.${FONT_COLOR_SUFFIX} 使用BBR+FQ_PIE加速 
 ${GREEN_FONT_PREFIX}22.${FONT_COLOR_SUFFIX} 使用BBR+CAKE加速        ${GREEN_FONT_PREFIX}23.${FONT_COLOR_SUFFIX} 使用BBRplus+FQ版加速
 ${GREEN_FONT_PREFIX}24.${FONT_COLOR_SUFFIX} 使用Lotserver(锐速)加速 ${GREEN_FONT_PREFIX}25.${FONT_COLOR_SUFFIX} 编译安装brutal模块
 ${GREEN_FONT_PREFIX}26.${FONT_COLOR_SUFFIX} 编译安装LotSpeed模块    ${GREEN_FONT_PREFIX}27.${FONT_COLOR_SUFFIX} 使用LotSpeed加速
 ———————————————————————————— 系统配置 —————————————————————————————
 ${GREEN_FONT_PREFIX}30.${FONT_COLOR_SUFFIX} 开启ECN                 ${GREEN_FONT_PREFIX}31.${FONT_COLOR_SUFFIX} 关闭ECN
 ${GREEN_FONT_PREFIX}32.${FONT_COLOR_SUFFIX} 系统网络自适应优化      ${GREEN_FONT_PREFIX}33.${FONT_COLOR_SUFFIX} 防CC/DDOS轻量优化
 ${GREEN_FONT_PREFIX}35.${FONT_COLOR_SUFFIX} 禁用IPv6                ${GREEN_FONT_PREFIX}36.${FONT_COLOR_SUFFIX} 开启IPv6
 ${GREEN_FONT_PREFIX}37.${FONT_COLOR_SUFFIX} 手动提交合并内核参数    ${GREEN_FONT_PREFIX}38.${FONT_COLOR_SUFFIX} 手动编辑内核参数
 ${GREEN_FONT_PREFIX}40.${FONT_COLOR_SUFFIX} Linux网络优化工具
 ———————————————————————————— 内核管理 —————————————————————————————
 ${GREEN_FONT_PREFIX}51.${FONT_COLOR_SUFFIX} 查看排序内核            ${GREEN_FONT_PREFIX}52.${FONT_COLOR_SUFFIX} 删除保留指定内核
 ${GREEN_FONT_PREFIX}55.${FONT_COLOR_SUFFIX} 卸载全部加速            ${GREEN_FONT_PREFIX}99.${FONT_COLOR_SUFFIX} 退出脚本 
————————————————————————————————————————————————————————————————"
	check_status
	get_system_info
	echo -e " 信息： ${FONT_COLOR_SUFFIX}$opsy ${GREEN_FONT_PREFIX}$virtual${FONT_COLOR_SUFFIX} $arch ${GREEN_FONT_PREFIX}$kern${FONT_COLOR_SUFFIX} "
	if [[ ${kernel_status} == "noinstall" ]]; then
		echo -e " 状态: ${GREEN_FONT_PREFIX}未安装${FONT_COLOR_SUFFIX} 加速内核 ${RED_FONT_PREFIX}请先安装内核${FONT_COLOR_SUFFIX}"
	else
		echo -e " 状态: ${GREEN_FONT_PREFIX}已安装${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${kernel_status}${FONT_COLOR_SUFFIX} 加速内核 , ${GREEN_FONT_PREFIX}${run_status}${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${brutal}${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${lotspeed_status}${FONT_COLOR_SUFFIX}"
	fi
	echo -e " 拥塞控制算法: ${GREEN_FONT_PREFIX}${net_congestion_control}${FONT_COLOR_SUFFIX} 队列算法: ${GREEN_FONT_PREFIX}${net_qdisc}${FONT_COLOR_SUFFIX} Headers状态：${GREEN_FONT_PREFIX}${headers_status}${FONT_COLOR_SUFFIX}"

	read -p " 请输入数字 :" num
	case "$num" in
	0) Update_Shell ;;
	1) installbbr ;;
	2) installbbrplus ;;
	3) installlot ;;
	4) installcloud ;;
	5) installbbrplusnew ;;
	6) check_sys_official_zen ;;
	7) check_sys_official ;;
	8) check_sys_official_bbr ;;
	9) check_sys_official_xanmod_main ;;
	10) check_sys_official_xanmod_lts ;;
	11) check_sys_official_xanmod_edge ;;
	12) check_sys_official_xanmod_rt ;;
	20) enable_acceleration "fq" "bbr" ;;
	21) enable_acceleration "fq_pie" "bbr" ;;
	22) enable_acceleration "cake" "bbr" ;;
	23) enable_acceleration "fq" "bbrplus" ;;
	24) startlotserver ;;
	25) startbrutal ;;
	26) install_lotspeed ;;
	27) enable_lotspeed_standalone ;;
	30) set_ecn "1" ;;
	31) set_ecn "0" ;;
	32) optimizing_system ;;
	33) optimizing_ddcc ;;
	35) closeipv6 ;;
	36) openipv6 ;;
	37) update_sysctl_interactive ;;
	38) edit_sysctl_interactive ;;
	40) sxui_network_tools_menu ;;
	51) show_kernels ;;
	52) delete_kernel_custom ;;
	55) remove_all ;;
	60) gotoipcheck ;;
	91) gototcp ;;
	92) gotodd ;;
	99) exit 1 ;;
	*)
		clear
		echo -e "${ERROR}: 请输入正确数字"
		sleep 3s
		start_menu
		;;
	esac
}

#-----------------------------------------------------------------------
# 函数: update_sysctl_interactive (V4 - 增加错误忽略参数)
# 功能: 以交互方式安全地更新 sysctl 配置文件并应用。
#       命令执行失败时，将不会回滚文件更改。
#-----------------------------------------------------------------------
update_sysctl_interactive() {
	# 强制使用C语言环境，确保正则表达式的行为可预测且一致。
	local LC_ALL=C

	# --- 配置与参数解析 ---
	local CONF_FILE="/etc/sysctl.d/99-sysctl.conf"
	local TMP_FILE
	local BACKUP_FILE
	local ignore_apply_error=true

	# --- 帮助函数 ---
	log_info() {
		echo "[INFO] $1"
	}

	log_error() {
		echo "[ERROR] $1" >&2
	}

	log_warn() {
		echo "[WARN] $1" >&2
	}

	# --- 主逻辑 ---

	# 1. 权限检查
	if [[ $EUID -ne 0 ]]; then
		log_error "此函数必须以 root 权限运行，请使用 sudo。"
		return 1
	fi

	# 2. 交互式获取用户输入
	log_info "请输入或粘贴您要设置的 sysctl 参数 (格式: key = value)。"
	log_info "可参考TCP迷之调参，https://omnitt.com/"
	log_info "注释行(以 # 或 ; 开头)和空行将被忽略。"
	log_info "最后一行请以空行结束 可手动回车加一行空行"
	log_info "输入完成后，请按 Ctrl+D 结束输入。"

	readarray -t user_input

	if [ ${#user_input[@]} -eq 0 ]; then
		log_info "没有接收到任何输入，操作已取消。"
		return 0
	fi

	# 确保配置文件存在
	touch "$CONF_FILE"

	# 3. 创建临时文件
	TMP_FILE=$(mktemp) || {
		log_error "无法创建临时文件"
		return 1
	}
	trap 'rm -f "$TMP_FILE"' RETURN

	cp "$CONF_FILE" "$TMP_FILE"

	local -A params_to_add
	local all_params_valid=true

	# 4. 预处理所有输入，检查合法性
	log_info "正在校验所有输入参数..."
	for line in "${user_input[@]}"; do
		trimmed_line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

		if [[ -z "$trimmed_line" ]] || [[ "$trimmed_line" =~ ^[[:space:]]*[#\;] ]]; then
			continue
		fi

		if ! [[ "$trimmed_line" =~ ^[[:space:]]*([a-zA-Z0-9._-]+)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
			log_error "格式无效: '$trimmed_line'. 期望格式为 'key = value'."
			all_params_valid=false
			continue
		fi

		local key="${BASH_REMATCH[1]}"
		local value="${BASH_REMATCH[2]}"

		if ! sysctl -N "$key" >/dev/null 2>&1; then
			log_error "参数键名无效: '$key' 不是一个有效的内核参数。"
			all_params_valid=false
			continue
		fi

		local formatted_param="$key = $value"

		if grep -q -E "^[[:space:]]*${key//./\\.}([[:space:]]*)=.*" "$TMP_FILE"; then
			sed -i -E "s|^[[:space:]]*${key//./\\.}([[:space:]]*)=.*|$formatted_param|" "$TMP_FILE"
			log_info "已更新参数: $formatted_param"
		else
			if [[ -z "${params_to_add[$key]}" ]]; then
				params_to_add["$key"]="$formatted_param"
			fi
		fi
	done

	if ! $all_params_valid; then
		log_error "检测到无效参数，操作已中止。配置文件未做任何更改。"
		return 1
	fi

	# 5. 将所有新参数追加到临时文件末尾
	if [ ${#params_to_add[@]} -gt 0 ]; then
		log_info "正在添加新参数..."
		echo "" >>"$TMP_FILE"
		for key in "${!params_to_add[@]}"; do
			echo "${params_to_add[$key]}" >>"$TMP_FILE"
			log_info "已添加新参数: ${params_to_add[$key]}"
		done
	fi

	# 6. 原子替换与应用
	BACKUP_FILE="${CONF_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
	cp "$CONF_FILE" "$BACKUP_FILE"
	log_info "原始文件已备份到 $BACKUP_FILE"

	mv "$TMP_FILE" "$CONF_FILE"
	chown root:root "$CONF_FILE"
	chmod 644 "$CONF_FILE"
	trap - RETURN

	# 7. 应用配置并进行错误处理
	log_info "正在应用新�� sysctl 设置..."
	if apply_output=$(sysctl -p "$CONF_FILE" 2>&1); then
		log_info "Sysctl 设置已成功应用。"
		echo "--- 应用输出 ---"
		echo "$apply_output"
		echo "------------------"
		rm -f "$BACKUP_FILE"
	else
		# 应用失败时的逻辑
		if [[ "$ignore_apply_error" == "true" ]]; then
			log_warn "应用 sysctl 设置失败，但根据指令已忽略错误。"
			log_warn "配置文件 '${CONF_FILE}' 已被更新，但部分设置可能未生效。"
			log_warn "--- 错误详情 ---"
			echo "$apply_output" >&2
			echo "------------------"
			rm -f "$BACKUP_FILE" # 忽略错误，所以也删除备份
			return 0             # 返回成功状态
		else
			log_error "应用 sysctl 设置失败！正在回滚..."
			log_error "--- 错误详情 ---"
			echo "$apply_output"
			echo "------------------"

			mv "$BACKUP_FILE" "$CONF_FILE"
			log_info "正在恢复到之前的设置..."
			sysctl -p "$CONF_FILE" >/dev/null 2>&1

			log_error "回滚完成。配置文件已恢复，问题备份文件保留在 $BACKUP_FILE"
			return 1
		fi
	fi

	return 0
}

edit_sysctl_interactive() {
	local target_file="/etc/sysctl.d/99-sysctl.conf"
	local editor_cmd=""

	# --- 1. 检查文件是否存在 ---
	if [ ! -f "$target_file" ]; then
		echo "文件 $target_file 不存在。"
		# (Y/n) 格式，n/N 以外的任何输入（包括回车）都将继续
		read -r -p "您想现在创建并编辑它吗？ (Y/n): " create_choice

		case "$create_choice" in
		[nN])
			echo "操作已取消。"
			return 0 # 0 表示成功（用户主动取消）
			;;
		*)
			echo "好的，准备创建并打开编辑器..."
			# 注意：我们不需要在这里 'touch' 文件。
			# 'sudo' 配合编辑器（如 nano 或 vi）在保存时会自动创建文件。
			;;
		esac
	fi

	# --- 2. 检查并选择编辑器 ---
	if command -v nano >/dev/null; then
		# 优先使用 nano
		editor_cmd="nano"
	else
		# nano 不存在，提示安装
		echo "首选编辑器 'nano' 未安装。"
		# (Y/n) 格式，n/N 以外的任何输入（包括回车）都将继续
		read -r -p "您想现在安装 'nano' 吗？ (Y/n): " install_choice

		case "$install_choice" in
		[nN])
			# 用户不安装，回退到 vi
			echo "好的，将使用 'vi' 编辑器。"
			echo "提示：'vi' 启动后，按 'i' 键进入插入模式，'Esc' 键退出插入模式，"
			echo "   然后输入 ':wq' 保存并退出，或 ':q!' 不保存退出。"
			editor_cmd="vi"
			;;
		*)
			# 这是一个安全的设计：函数不应该自己执行安装。
			# 它应该指导用户，然后退出，让用户安装后重试。
			echo "请在您的终端中运行:"
			echo "  sudo apt install nano  (适用于 Debian/Ubuntu)"
			echo "  sudo dnf install nano  (适用于 Fedora/RHEL 8+)"
			echo "  sudo yum install nano  (适用于 CentOS 7)"
			echo "安装完成后，请重新运行此函数。"
			echo "操作已取消。"
			return 1 # 1 表示一个非0的退出码，表示未完成
			;;
		esac
	fi

	# --- 3. 执行编辑 ---
	echo "正在使用 $editor_cmd 打开 $target_file..."
	echo "请注意：编辑系统文件需要管理员权限，您可能需要输入密码。"

	# 使用 sudo 来运行编辑器，以便有权限写入 /etc/sysctl.d/ 目录
	if ! "$editor_cmd" "$target_file"; then
		echo "编辑器 '$editor_cmd' 启动失败或异常退出。"
		echo "请检查您的 sudo 权限或编辑器是否正确安装。"
		return 1
	fi

	# --- 4. (修改) 默认直接应用 ---
	echo ""
	echo "编辑完成。"
	echo "正在应用 $target_file 中的设置..."

	# -p 参数会从指定文件中加载设置
	sysctl -p "$target_file"
	echo "已执行应用，部分可能需要重启生效"
}

# =================================================
#  官方源内核安装模块 (修复自适应变量)
# =================================================

# =================================================
#  官方源内核安装模块 (包含 CentOS 10 战未来支持)
# =================================================

#检查官方稳定内核并安装
check_sys_official() {
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		[[ "${OS_ARCH}" != "x86_64" ]] && {
			echo -e "${ERROR} 不支持x86_64以外的系统 !"
			exit 1
		}
		if [[ "${OS_VERSION_ID}" == "7" ]]; then
			yum install kernel kernel-headers -y --skip-broken
		elif [[ "${OS_VERSION_ID}" == "8" || "${OS_VERSION_ID}" == "9" || "${OS_VERSION_ID}" == "10" ]]; then
			# CentOS 8、9、10 都是同样的包结构
			yum install kernel kernel-core kernel-headers -y --skip-broken
		else
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && exit 1
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt update
		if [[ "${OS_ARCH}" == "x86_64" ]]; then
			apt-get install linux-image-amd64 linux-headers-amd64 -y
		elif [[ "${OS_ARCH}" == "aarch64" ]]; then
			apt-get install linux-image-arm64 linux-headers-arm64 -y
		fi
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

#检查官方最新内核并安装 (ELRepo / Backports)
check_sys_official_bbr() {
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		[[ "${OS_ARCH}" != "x86_64" ]] && {
			echo -e "${ERROR} 不支持x86_64以外的系统 !"
			exit 1
		}
		rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
		if [[ "${OS_VERSION_ID}" == "7" ]]; then
			yum install https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm -y
			yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
		elif [[ "${OS_VERSION_ID}" == "8" ]]; then
			yum install https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm -y
			yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
		elif [[ "${OS_VERSION_ID}" == "9" ]]; then
			yum install https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm -y
			yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
		elif [[ "${OS_VERSION_ID}" == "10" ]]; then
			# 补充 CentOS 10 的 ELRepo 源安装逻辑 (战未来)
			yum install https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm -y
			yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
		else
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && exit 1
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local codename=$(lsb_release -cs 2>/dev/null || echo "")
		[[ -z "$codename" ]] && {
			echo -e "${ERROR} 无法获取 Debian 代号"
			exit 1
		}

		echo "deb http://deb.debian.org/debian ${codename}-backports main" >/etc/apt/sources.list.d/${codename}-backports.list
		apt update

		if [[ "${OS_ARCH}" == "x86_64" ]]; then
			apt -t "${codename}-backports" install linux-image-amd64 linux-headers-amd64 -y
		elif [[ "${OS_ARCH}" =~ ^(arm|aarch64)$ ]]; then
			apt -t "${codename}-backports" install linux-image-arm64 linux-headers-arm64 -y
		fi
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

# 统一 Xanmod 安装引擎
install_xanmod_generic() {
	local edition="$1" # main, lts, edge, rt
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} Xanmod 仅支持 x86_64 !"
		exit 1
	}
	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} 当前一键 Xanmod 仅支持 Debian/Ubuntu !"
		exit 1
	}

	apt update
	apt-get install gnupg gnupg2 gnupg1 wget -y

	# 清除可能存在的旧版或重复源 (兼容 PR 提到的 .sources 与冲突问题)
	rm -f /etc/apt/sources.list.d/xanmod-kernel.list
	rm -f /etc/apt/sources.list.d/xanmod-release.list
	rm -f /etc/apt/sources.list.d/xanmod-kernel.sources
	sed -i '/deb.xanmod.org/d' /etc/apt/sources.list 2>/dev/null

	# 使用现代化的 signed-by 格式写入 GPG 密钥与源，彻底消除 apt 警告
	wget -qO - https://dl.xanmod.org/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg
	echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list

	wget -qO check_x86-64_psabi.sh https://dl.xanmod.org/check_x86-64_psabi.sh
	chmod +x check_x86-64_psabi.sh
	local cpu_level=$(./check_x86-64_psabi.sh | awk -F 'v' '{print $2}')
	echo -e "${INFO} CPU 支持等级: \033[32mv${cpu_level}\033[0m"
	[[ -z "$cpu_level" ]] && cpu_level="1" # 默认 fallback

	apt update
	local pkg_name="linux-xanmod"
	[[ "$edition" != "main" ]] && pkg_name="linux-xanmod-${edition}"

	if [[ "$cpu_level" -ge 3 ]]; then
		apt install "${pkg_name}-x64v3" -y
	elif [[ "$cpu_level" == 2 ]]; then
		apt install "${pkg_name}-x64v2" -y
	else
		apt install "${pkg_name}-x64v1" -y
	fi

	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

check_sys_official_xanmod_main() { install_xanmod_generic "main"; }
check_sys_official_xanmod_lts() { install_xanmod_generic "lts"; }
check_sys_official_xanmod_edge() { install_xanmod_generic "edge"; }
check_sys_official_xanmod_rt() { install_xanmod_generic "rt"; }

#检查Zen官方内核并安装
check_sys_official_zen() {
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} Zen内核仅支持x86_64 !"
		exit 1
	}
	if [[ "${OS_ID}" == "debian" ]]; then
		curl -sL 'https://liquorix.net/add-liquorix-repo.sh' | bash
		apt-get install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	elif [[ "${OS_ID}" == "ubuntu" ]]; then
		apt-get install software-properties-common -y
		add-apt-repository ppa:damentz/liquorix -y && apt-get update
		apt-get install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	else
		echo -e "${ERROR} Zen内核当前脚本仅支持 Debian/Ubuntu !" && exit 1
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

#检查系统当前状态
check_status() {
	# 初始化变量，避免重复读取文件
	kernel_version=$(uname -r | awk -F "-" '{print $1}')
	kernel_version_full=$(uname -r)
	net_congestion_control=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
	net_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "unknown")

	# 检测内核类型
	if [[ "$kernel_version_full" == *bbrplus* ]]; then
		kernel_status="BBRplus"
	elif [[ "$kernel_version_full" =~ (4\.9\.0-4|4\.15\.0-30|4\.8\.0-36|3\.16\.0-77|3\.16\.0-4|3\.2\.0-4|4\.11\.2-1|2\.6\.32-504|4\.4\.0-47|3\.13\.0-29) ]]; then
		kernel_status="Lotserver"
	elif read major minor <<<$(echo "$kernel_version" | awk -F'.' '{print $1, $2}') &&
		{ [[ "$major" == "4" && "$minor" -ge 9 ]] || [[ "$major" -ge 5 ]]; }; then
		kernel_status="BBR"
	else
		kernel_status="noinstall"
	fi

	# 运行状态检测
	if [[ "$kernel_status" == "BBR" ]]; then
		case "$net_congestion_control" in
		"bbr")
			run_status="BBR启动成功"
			;;
		"bbr2")
			run_status="BBR2启动成功"
			;;
		"tsunami")
			if lsmod | grep -q "^tcp_tsunami"; then
				run_status="BBR魔改版启动成功"
			else
				run_status="BBR魔改版启动失败"
			fi
			;;
		"nanqinlang")
			if lsmod | grep -q "^tcp_nanqinlang"; then
				run_status="暴力BBR魔改版启动成功"
			else
				run_status="暴力BBR魔改版启动失败"
			fi
			;;
		*)
			run_status="未安装加速模块"
			;;
		esac
	elif [[ "$kernel_status" == "Lotserver" ]]; then
		if [[ -e /appex/bin/lotServer.sh ]]; then
			run_status=$(bash /appex/bin/lotServer.sh status | grep "LotServer" | awk '{print $3}')
			[[ "$run_status" == "running!" ]] && run_status="启动成功" || run_status="启动失败"
		else
			run_status="未安装加速模块"
		fi
	elif [[ "$kernel_status" == "BBRplus" ]]; then
		case "$net_congestion_control" in
		"bbrplus")
			run_status="BBRplus启动成功"
			;;
		"bbr")
			run_status="BBR启动成功"
			;;
		*)
			run_status="未安装加速模块"
			;;
		esac
	else
		run_status="未安装加速模块"
	fi

	# 检查 Headers 状态 (利用全局 OS_TYPE)
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		installed_headers=$(rpm -qa | grep -E "kernel-devel|kernel-headers" | grep -v '^$' || echo "")
		if [[ -z "$installed_headers" ]]; then
			headers_status="未安装"
		else
			if echo "$installed_headers" | grep -q "kernel-devel-${kernel_version_full}\|kernel-headers-${kernel_version_full}"; then
				headers_status="已匹配"
			else
				headers_status="未匹配"
			fi
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		installed_headers=$(dpkg -l | grep -E "linux-headers|linux-image" | awk '{print $2}' | grep -v '^$' || echo "")
		if [[ -z "$installed_headers" ]]; then
			headers_status="未安装"
		else
			if echo "$installed_headers" | grep -q "linux-headers-${kernel_version_full}"; then
				headers_status="已匹配"
			else
				headers_status="未匹配"
			fi
		fi
	else
		headers_status="不支持的操作系统"
	fi

	# Brutal 状态检测
	brutal=""
	if lsmod | grep -q "brutal"; then
		brutal="brutal已加载"
	fi

	# 新增：LotSpeed 状态检测
	lotspeed_status=""
	if lsmod | grep -q "lotspeed"; then
		if [[ "$net_congestion_control" == "lotspeed" ]]; then
			run_status="LotSpeed启动成功" # 直接覆盖掉上面错误的“未安装”提示
		else
			lotspeed_status="LotSpeed已加载(未设为默认)"
		fi
	fi
}

#############系统检测组件#############
# =================================================
#  入口执行逻辑
# =================================================

# 命令行静默调用参数解析 (免菜单执行)
if [ $# -gt 0 ]; then
	check_sys
	check_cn_status
	case $1 in
	op0 | op1 | op2)
		# 兼容老指令，重定向到自适应新版优化
		optimizing_system
		exit
		;;
	op3)
		update_sysctl_interactive
		exit
		;;
	op4)
		edit_sysctl_interactive
		exit
		;;
	*)
		echo -e "${ERROR} 未知选项: \"$1\""
		exit 1
		;;
	esac
fi

# 常规交互式启动
check_sys
check_cn_status
start_menu
