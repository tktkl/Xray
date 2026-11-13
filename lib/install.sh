#!/usr/bin/env bash
download_verified() {
    local url=$1 output=$2 digest=$3
    [[ $digest =~ ^[a-f0-9]{64}$ ]] || { die '清单中的 SHA256 无效。'; return; }
    if [[ -n ${DOWNLOAD_CACHE:-} && -f $DOWNLOAD_CACHE/${url##*/} ]]; then
        cp "$DOWNLOAD_CACHE/${url##*/}" "$output"
        printf '%s  %s\n' "$digest" "$output" | sha256sum -c - >/dev/null || { rm -f "$output"; die '离线缓存摘要不匹配。'; return; }
        return
    fi
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' --tlsv1.2 "$url" --output "$output" || return
    printf '%s  %s\n' "$digest" "$output" | sha256sum -c - >/dev/null || { rm -f "$output"; die '下载内容 SHA256 校验失败。'; return; }
}
download_core() {
    local info
    info=$(core_release_info "$1") || return
    core_fetch_binary "$info" "$2"
}
download_data() {
    local dest=$1 version name sha tmp
    version=$(jq -r '.data.version' "$MANAGER_HOME/config/releases.json")
    tmp=$(mktemp -d)
    for name in geoip.dat geosite.dat; do
        sha=$(jq -r --arg n "$name" '.data[$n]' "$MANAGER_HOME/config/releases.json")
        download_verified "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$version/$name" "$tmp/$name" "$sha" || { rm -rf "$tmp"; return 1; }
    done
    mkdir -p "$dest"
    install -m 644 "$tmp/geoip.dat" "$tmp/geosite.dat" "$dest/"
    rm -rf "$tmp"
}
record_component() {
    local name=$1 created=$2 file="$ROOT/ownership.json"
    [[ -e $file ]] || printf '{}\n' > "$file"
    jq --arg n "$name" --argjson c "$created" 'if has($n) then . else .[$n]=$c end' "$file" | atomic_file "$file"
}
ensure_component() {
    local component=$1 existed=false
    require_root
    case $component in
        nginx)
            command -v nginx >/dev/null && existed=true
            if [[ $existed == false ]]; then apt-get update && apt-get install -y nginx || return; fi
            record_component nginx "$([[ $existed == false ]] && echo true || echo false)"
            nginx_install_loader || return
            mkdir -p /etc/systemd/system/nginx.service.d
            printf '[Unit]\nAfter=xray-manager-recover.service\nWants=xray-manager-recover.service\n' > /etc/systemd/system/nginx.service.d/xray-manager.conf
            systemctl daemon-reload
            ;;
        certbot)
            command -v certbot >/dev/null && existed=true
            if ! command -v certbot >/dev/null || ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
                apt-get update && apt-get install -y certbot python3-certbot-dns-cloudflare || return
            fi
            record_component certbot "$([[ $existed == false ]] && echo true || echo false)"
            systemctl enable --now certbot.timer xray-cert-deploy.timer || return;;
    esac
}
install_manager() {
    require_root
    local target=/usr/local/lib/xray-manager source_home=$MANAGER_HOME os_id os_version stage default_core
    if (($#)); then
        [[ $# == 2 && $1 == --offline-cache && -d $2 ]] || { die '用法：install.sh [--offline-cache DIR]'; return; }
        DOWNLOAD_CACHE=$(readlink -f "$2")
    fi
    [[ -e /etc/os-release ]] || { die '仅支持 Debian/Ubuntu。'; return; }
    os_id=$(. /etc/os-release; printf '%s' "$ID")
    os_version=$(. /etc/os-release; printf '%s' "$VERSION_ID")
    case "$os_id:$os_version" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) die '当前系统不在支持矩阵中。'; return 1;; esac
    [[ $(ps -p 1 -o comm=) == systemd ]] || { die '安装需要 systemd；容器测试请使用 systemd 测试模式。'; return; }
    if [[ -e /usr/local/bin/xray || -L /usr/local/bin/xray ]] || command -v xray >/dev/null || systemctl cat xray.service >/dev/null 2>&1; then
        die '检测到已有 Xray 命令或服务，拒绝覆盖。'; return 1
    fi
    [[ ! -e $target && ! -e $ROOT/ownership.json ]] || { die '已有管理器，请使用 update 或 reinstall。'; return; }
    local missing=false dependency
    for dependency in jq curl openssl unzip ss flock qrencode; do command -v "$dependency" >/dev/null || missing=true; done
    if [[ $missing == true ]]; then apt-get update && apt-get install -y --no-install-recommends bash jq curl ca-certificates openssl unzip iproute2 util-linux qrencode || return; fi
    id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    mkdir -p /usr/local/lib "$ROOT/logs"
    stage=$(mktemp -d /usr/local/lib/.xray-manager-install.XXXXXX)
    chmod 755 "$stage"
    cp -a "$source_home/bin" "$source_home/lib" "$source_home/jq" "$source_home/config" "$source_home/systemd" "$stage/"
    cp "$source_home/bootstrap.sh" "$stage/bootstrap.sh"
    chmod 755 "$stage/bin/xray"
    MANAGER_HOME=$stage
    default_core=$(jq -er .default_core "$stage/config/releases.json") || return
    if ! download_core "$default_core" "$stage/core" || ! download_data "$stage/core"; then
        MANAGER_HOME=$source_home; rm -rf "$stage"; return 1
    fi
    mkdir -p "$target/releases" "$target/core"
    chmod 755 "$target" "$target/releases" "$target/core"
    mv "$stage/core/"* "$target/core/"
    rmdir "$stage/core"
    mv "$stage" "$target/releases/v$VERSION"
    ln -s "$target/releases/v$VERSION" "$target/code-current"
    for dependency in bin lib jq config systemd; do ln -s "$target/code-current/$dependency" "$target/$dependency"; done
    MANAGER_HOME=$target
    chown "$SERVICE_USER:$SERVICE_USER" "$ROOT/logs"
    chmod 750 "$ROOT/logs"
    lock_state; store_init; load_state
    # Bootstrap an empty, valid fail-closed configuration before enabling services.
    new_generation
    as_service "$CORE" run -test -c "$CANDIDATE/config.json" >/dev/null || { unlock_state; return 1; }
    atomic_link "$CANDIDATE" "$ROOT/current"; atomic_link "$CANDIDATE" "$ROOT/installed"
    record_component manager true
    unlock_state
    install -m 644 "$target"/systemd/* /etc/systemd/system/
    ln -s "$target/bin/xray" /usr/local/bin/xray
    systemctl daemon-reload
    systemctl enable --now xray-manager-recover.service xray-manager.service
    note '安装完成。执行 xray 打开菜单，或 xray a reality 添加节点。'
}
update_data() {
    local tmp previous running=false file
    tmp=$(mktemp -d "$ROOT/data-update.XXXXXX")
    download_data "$tmp/new" || { rm -rf "$tmp"; return 1; }
    systemctl start xray-manager-recover.service || return
    write_begin || return
    previous="$ROOT/data-backup"
    mkdir -p "$previous"
    cp -p "$ASSETS/geoip.dat" "$ASSETS/geosite.dat" "$previous/" || { unlock_state; return 1; }
    sync_path "$previous"
    service_active xray-manager.service && running=true
    jq -n --arg backup "$previous" --argjson running "$running" '{backup:$backup,was_running:$running}' | atomic_file "$ROOT/data-upgrade.json"
    for file in geoip.dat geosite.dat; do install -m 644 "$tmp/new/$file" "$ASSETS/$file.next" && mv -f "$ASSETS/$file.next" "$ASSETS/$file" || { unlock_state; return 1; }; done
    if ! as_service "$CORE" run -test -c "$ROOT/current/config.json" >/dev/null ||
       { [[ $running == true ]] && { ! systemctl restart xray-manager.service || ! wait_api; }; }; then
        recover_state || { unlock_state; return 1; }
        unlock_state; rm -rf "$tmp"; die '规则数据升级失败，已恢复。'; return 1
    fi
    rm -f "$ROOT/data-upgrade.json"
    sync_path "$ROOT"
    unlock_state
    rm -rf "$tmp"
}
update_core() {
    local version=latest tmp running=false info current check=false latest=false
    if (($#)) && [[ $1 != -* ]]; then version=$1; shift; fi
    while (($#)); do
        case $1 in --check) check=true; shift;; *) die '用法：xray update core [版本|latest] [--check]'; return;; esac
    done
    if [[ $version == latest ]]; then latest=true; version=$(latest_core_version) || return; fi
    info=$(core_release_info "$version") || return
    core_field_report "$info" || return
    current=$(core_version "$CORE") || return
    if [[ $latest == true && $current == "$version" && $check == false ]]; then
        note "核心已是官方最新正式版 $version，无需重启。"; return
    fi
    tmp=$(mktemp -d "$ROOT/core-update.XXXXXX")
    chown "root:$SERVICE_USER" "$tmp"; chmod 750 "$tmp"
    core_fetch_binary "$info" "$tmp" || { rm -rf "$tmp"; return 1; }
    if [[ $(as_service "$tmp/xray" version | awk '$1=="Xray" && !seen {print "v"$2; seen=1}') != "$version" ]]; then
        rm -rf "$tmp"; die '候选核心实际版本与发布标签不一致。'; return
    fi
    if ! as_service "$tmp/xray" run -test -c "$ROOT/current/config.json" > "$ROOT/core-update-error.log" 2>&1 ||
       ! core_api_probe "$tmp/xray" "$tmp/probe" >> "$ROOT/core-update-error.log" 2>&1; then
        rm -rf "$tmp"; die "候选核心配置或 API 验证失败；现有核心未改变。诊断：$ROOT/core-update-error.log"; return
    fi
    if [[ $check == true ]]; then
        rm -rf "$tmp"; note "核心 $version 的现有配置及管理 API 检查通过，未替换核心。"; return
    fi
    note "核心更新 $current → $version 是全局操作，将重新启动所有正在运行的节点。"
    systemctl start xray-manager-recover.service || { rm -rf "$tmp"; return 1; }
    write_begin || { unlock_state; rm -rf "$tmp"; return 1; }
    # Nodes may have changed while downloading; validate the committed configuration again under lock.
    as_service "$tmp/xray" run -test -c "$ROOT/current/config.json" > "$ROOT/core-update-error.log" 2>&1 || {
        unlock_state; rm -rf "$tmp"; die "当前配置已变化且无法通过候选核心验证。诊断：$ROOT/core-update-error.log"; return;
    }
    service_active xray-manager.service && running=true
    mkdir -p "$ROOT/core-backups"
    install -m 755 "$CORE" "$ROOT/core-backups/previous" && sync_path "$ROOT/core-backups/previous" || {
        unlock_state; rm -rf "$tmp"; return 1;
    }
    jq -n --arg previous "$ROOT/core-backups/previous" --argjson running "$running" \
        '{previous:$previous,was_running:$running}' | atomic_file "$ROOT/core-upgrade.json" || {
        unlock_state; rm -rf "$tmp"; return 1;
    }
    if { [[ $running == true ]] && ! systemctl stop xray-manager.service; } ||
       ! install -m 755 "$tmp/xray" "${CORE}.next" || ! sync_path "${CORE}.next" ||
       ! mv -f "${CORE}.next" "$CORE" || ! sync_path "$(dirname -- "$CORE")" ||
       { [[ $running == true ]] && { ! systemctl start xray-manager.service || ! wait_api || ! core_runtime_matches; }; }; then
        if recover_state; then note '核心升级失败，已恢复旧核心。'
        else note "核心升级及恢复失败；恢复记录保留在 $ROOT/core-upgrade.json。"; fi
        unlock_state; rm -rf "$tmp"; return 1
    fi
    rm -f "$ROOT/core-upgrade.json"
    sync_path "$ROOT"
    unlock_state
    rm -rf "$tmp"
    note "核心已更新至 $version。"
}
wait_api() {
    local i
    for ((i=0;i<20;i++)); do if api_json lsi --isOnlyTags=true >/dev/null 2>&1; then return; fi; sleep 0.5; done
    return 1
}
latest_manager_version() {
    local destination
    need curl || return
    destination=$(curl --fail --silent --show-error --location --user-agent 'Xray-independent-updater' \
        --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \
        --connect-timeout 15 --max-time 60 --output /dev/null --write-out '%{url_effective}' \
        'https://github.com/tktkl/Xray/releases/latest') || {
        die '无法查询最新正式版，请检查网络，或指定已发布版本。'; return;
    }
    [[ $destination =~ ^https://github\.com/tktkl/Xray/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || {
        die '最新正式版地址无效，未更新脚本。'; return;
    }
    printf '%s' "${BASH_REMATCH[1]}"
}
update_manager() {
    local version=latest tmp install_home=/usr/local/lib/xray-manager release previous code_fd f
    local -a download_options=()
    if (($#)) && [[ $1 != -* ]]; then version=${1:-latest}; shift; fi
    while (($#)); do
        case $1 in
            --sha256)
                [[ $# -ge 2 && ${2:-} =~ ^[a-fA-F0-9]{64}$ ]] || { die '指定的 SHA256 格式不正确。'; return; }
                download_options+=(--sha256 "$2"); shift 2;;
            *) die '用法：xray update sh [版本|latest] [--sha256 SHA256]'; return;;
        esac
    done
    if [[ $version == latest ]]; then
        version=$(latest_manager_version) || return
        if [[ $version == "v$VERSION" ]]; then note "管理脚本已是最新正式版 $version。"; return; fi
        note "最新正式版：$version。"
    fi
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { die "版本格式应为 v数字.数字.数字；省略版本更新最新正式版。"; return; }
    [[ -f $MANAGER_HOME/bootstrap.sh ]] || { die '缺少 Release 下载入口，请使用新版安装包。'; return; }
    tmp=$(mktemp -d "$ROOT/script-update.XXXXXX")
    if ! bash "$MANAGER_HOME/bootstrap.sh" --version "$version" --download-only "$tmp/source" "${download_options[@]}"; then
        rm -rf "$tmp"; return 1
    fi
    [[ -x $tmp/source/bin/xray && -d $tmp/source/lib && -d $tmp/source/jq ]] || { rm -rf "$tmp"; die '发布包结构无效。'; return; }
    for f in "$tmp/source/bin/xray" "$tmp/source/lib/"*.sh; do bash -n "$f" || { rm -rf "$tmp"; return 1; }; done
    exec {code_fd}>"$ROOT/code-update.lock"
    flock -w 30 "$code_fd" || return 1
    release="$install_home/releases/$version-$(random_hex 8)"
    mv "$tmp/source" "$release"
    chmod -R u+rwX,go+rX "$release"
    if ! XRAY_MANAGER_HOME="$release" "$release/bin/xray" test; then
        rm -rf "$release" "$tmp"; die '候选脚本验证失败，当前版本未改变。'; return
    fi
    previous=$(readlink -f "$install_home/code-current")
    sync_path "$release"
    atomic_link "$release" "$install_home/code-current"
    if ! XRAY_MANAGER_HOME="$release" "$install_home/bin/xray" test; then
        atomic_link "$previous" "$install_home/code-current"
        rm -rf "$tmp"; die '脚本升级验证失败，已恢复。'; return
    fi
    flock -u "$code_fd"; exec {code_fd}>&-
    rm -rf "$tmp"
    note "管理脚本已更新至 $version。"
}
uninstall_manager() {
    require_root
    [[ $(jq -r '.manager // false' "$ROOT/ownership.json") == true ]] || { die '缺少管理器所有权记录。'; return; }
    note '卸载受管服务和站点，配置备份、证书、Token 及共享软件包保留。'
    systemctl disable --now xray-manager.service xray-cert-deploy.timer xray-manager-recover.service || return
    rm -f /usr/local/bin/xray
    rm -f /etc/systemd/system/xray-manager.service /etc/systemd/system/xray-manager-recover.service /etc/systemd/system/xray-cert-deploy.{service,timer}
    if [[ -e $NGINX_LOADER ]] && grep -Fq "include $ROOT/installed/nginx/*.conf;" "$NGINX_LOADER"; then
        rm -f "$NGINX_LOADER" /etc/systemd/system/nginx.service.d/xray-manager.conf
        if service_active nginx.service; then nginx -t && systemctl reload nginx.service; fi
    fi
    systemctl daemon-reload
    # Remove automatic invocations from ONLY the lineages we own.
    local f domain
    for f in "$ROOT"/managed-certificates/*.json; do
        [[ -e $f ]] || continue
        domain=$(basename "$f" .json)
        if [[ -e $LE_DIR/renewal/xray-$domain.conf ]]; then
            sed -i '\|^renew_hook = .*xray.*cert enqueue$|d;\|^deploy_hook = .*xray.*cert enqueue$|d' "$LE_DIR/renewal/xray-$domain.conf"
        fi
    done
    rm -rf /usr/local/lib/xray-manager
    note "卸载完成，恢复资料保存在 $ROOT。"
}
