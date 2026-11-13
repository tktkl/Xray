#!/usr/bin/env bash
# Standalone installer: this file can be copied to a server without the repository.
set -Eeuo pipefail
umask 077
DEFAULT_VERSION='v0.1.7'
REPOSITORY='tktkl/Xray'
WORK=''

fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Xray 一键安装入口（公开仓库，无需 GitHub Token）
用法：sudo bash bootstrap.sh [选项]
  --version v0.1.7             安装指定 Release（默认与入口脚本版本一致）
  --sha256 SHA256             使用另外核实的程序包摘要
  --offline-cache DIR         使用本地核心/规则数据缓存
  -h, --help                  显示帮助

自动下载指定版本的完整 Release 包，验证摘要后安装。
Cloudflare Token 仅在需要签发证书时另外设置。
EOF
}
cleanup() { [[ -z $WORK ]] || rm -rf -- "$WORK"; }
fetch_release() {
    local name=$1 dest=$2 version=$3 url
    case $name in SHA256SUMS|"xray-manager-$version.tar.gz") ;; *) fail '拒绝非预期的发布附件。';; esac
    url="https://github.com/$REPOSITORY/releases/download/$version/$name"
    curl --fail --silent --show-error --location --user-agent 'Xray-independent-installer' \
        --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \
        --connect-timeout 15 --max-time 300 \
        --output "$dest" "$url" || fail '无法下载公开 Release；请检查网络、仓库可见性及版本是否已发布。'
}
validate_archive() {
    local archive=$1
    tar -tPzf "$archive" > "$WORK/names" || fail '无法读取程序包。'
    awk '
      /^\// || /(^|\/)\.\.($|\/)/ || /\\/ {bad=1}
      END {exit bad}
    ' "$WORK/names" || fail '程序包包含不安全路径。'
    tar -tvzf "$archive" > "$WORK/types" || fail '程序包结构无效。'
    awk 'substr($1,1,1)!="-" && substr($1,1,1)!="d" {bad=1} END{exit bad}' "$WORK/types" ||
        fail '程序包包含链接、设备或其他非普通文件。'
}
main() {
    local version=$DEFAULT_VERSION supplied_digest='' cache='' destination=''
    local package digest entry
    while (($#)); do
        case $1 in
            -h|--help) usage; return;;
            --version|--sha256|--offline-cache|--download-only)
                (($#>=2)) || fail "$1 缺少参数。"
                case $1 in
                    --version) version=$2;;
                    --sha256) supplied_digest=$2;; --offline-cache) cache=$2;; --download-only) destination=$2;;
                esac
                shift 2;;
            *) fail "未知参数：$1";;
        esac
    done
    (( EUID == 0 )) || fail '请使用 root 或 sudo 运行。'
    [[ $(uname -s) == Linux ]] || fail '安装目标需要 Linux。'
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '版本必须是 v数字.数字.数字，不接受分支名。'
    [[ -z $supplied_digest || $supplied_digest =~ ^[a-fA-F0-9]{64}$ ]] || fail '指定的 SHA256 格式不正确。'
    [[ -z $cache || -d $cache ]] || fail '离线缓存目录不存在。'
    [[ -z $destination || ( ! -e $destination && ! -L $destination && -d $(dirname -- "$destination") ) ]] || fail '下载目录必须尚不存在，且父目录已存在。'
    [[ -e /etc/os-release ]] || fail '仅支持 Debian/Ubuntu。'
    local os_id os_version
    os_id=$(. /etc/os-release; printf '%s' "$ID")
    os_version=$(. /etc/os-release; printf '%s' "$VERSION_ID")
    case "$os_id:$os_version" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) fail '系统不在支持矩阵中。';; esac
    local dependency missing=false
    for dependency in curl tar sha256sum; do command -v "$dependency" >/dev/null || missing=true; done
    if [[ $missing == true || ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        apt-get update && apt-get install -y --no-install-recommends curl ca-certificates tar coreutils || fail '安装下载依赖失败。'
    fi
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/xray-bootstrap.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '下载 %s 的 %s 安装包……\n' "$REPOSITORY" "$version" >&2
    package="xray-manager-$version.tar.gz"
    if [[ -n $supplied_digest ]]; then
        digest=${supplied_digest,,}
    else
        fetch_release SHA256SUMS "$WORK/SHA256SUMS" "$version"
        digest=$(awk -v name="$package" 'NF==2 && $2==name {print $1}' "$WORK/SHA256SUMS")
        [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || fail '发布包摘要缺失、重复或格式不正确。'
        digest=${digest,,}
    fi
    fetch_release "$package" "$WORK/$package" "$version"
    printf '%s  %s\n' "$digest" "$WORK/$package" | sha256sum -c - >/dev/null || fail '程序包 SHA256 不匹配，未执行安装。'
    validate_archive "$WORK/$package"
    mkdir "$WORK/source"
    tar -xzf "$WORK/$package" --no-same-owner --no-same-permissions -C "$WORK/source" || fail '解压失败。'
    for entry in bin/xray lib/common.sh lib/install.sh jq/render.jq config/releases.json systemd/xray-manager.service; do
        [[ -s $WORK/source/$entry ]] || fail "发布包缺少文件：$entry"
    done
    for entry in "$WORK/source/bin/xray" "$WORK/source/lib/"*.sh; do bash -n "$entry" || fail '发布脚本语法检查失败。'; done
    if [[ -n $destination ]]; then
        mv "$WORK/source" "$destination"
        return
    fi
    local -a install_args=(install)
    [[ -z $cache ]] || install_args+=(--offline-cache "$cache")
    XRAY_MANAGER_HOME="$WORK/source" bash "$WORK/source/bin/xray" "${install_args[@]}"
}
main "$@"
