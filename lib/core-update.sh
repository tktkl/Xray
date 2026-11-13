#!/usr/bin/env bash
core_version() {
    "$1" version | awk '$1=="Xray" && !seen {print "v"$2; seen=1}'
}
latest_core_version() {
    local destination
    destination=$(curl --fail --silent --show-error --location --header 'Cache-Control: no-cache' \
        --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 60 \
        --output /dev/null --write-out '%{url_effective}' 'https://github.com/XTLS/Xray-core/releases/latest') || {
        die '无法查询 Xray 官方最新正式版。'; return;
    }
    [[ $destination =~ ^https://github\.com/XTLS/Xray-core/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || {
        die 'Xray 官方最新正式版地址无效。'; return;
    }
    printf '%s' "${BASH_REMATCH[1]}"
}
core_fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 2 --connect-timeout 15 --max-time 180 --output "$2" "$1"
}
core_release_info() (
    local version=$1 arch asset digest tmp known=true
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { die '核心版本必须是 v数字.数字.数字。'; return; }
    case $(uname -m) in
        x86_64) arch=amd64; asset=Xray-linux-64.zip;;
        aarch64|arm64) arch=arm64; asset=Xray-linux-arm64-v8a.zip;;
        *) die '只支持 amd64/arm64。'; return;;
    esac
    digest=$(jq -r --arg v "$version" --arg a "$arch" '.core[$v][$a].sha256 // empty' "$MANAGER_HOME/config/releases.json") || return
    if [[ -z $digest ]]; then
        known=false
        tmp=$(mktemp -d) || return
        trap 'rm -rf -- "$tmp"' EXIT
        core_fetch "https://github.com/XTLS/Xray-core/releases/download/$version/$asset.dgst" "$tmp/digest" || return
        digest=$(awk '$1=="SHA2-256=" && NF==2 {print tolower($2)}' "$tmp/digest")
    fi
    [[ $digest =~ ^[a-f0-9]{64}$ ]] || { die '官方核心 SHA256 缺失、重复或格式无效。'; return; }
    jq -n --arg version "$version" --arg asset "$asset" --arg sha256 "$digest" --argjson tested "$known" \
        '{version:$version,asset:$asset,sha256:$sha256,tested:$tested}'
)
core_fetch_binary() (
    local info=$1 destination=$2 version asset digest tmp
    version=$(jq -r .version <<< "$info"); asset=$(jq -r .asset <<< "$info"); digest=$(jq -r .sha256 <<< "$info")
    tmp=$(mktemp -d) || return
    trap 'rm -rf -- "$tmp"' EXIT
    download_verified "https://github.com/XTLS/Xray-core/releases/download/$version/$asset" "$tmp/core.zip" "$digest" || return
    # Read only the binary; do not extract archive paths or links as root.
    [[ $(unzip -Z -1 "$tmp/core.zip" | awk '$0=="xray" {n++} END{print n+0}') == 1 ]] || {
        die '核心压缩包缺少唯一的 xray 文件。'; return;
    }
    unzip -p "$tmp/core.zip" xray > "$tmp/xray" || return
    mkdir -p "$destination" && install -m 755 "$tmp/xray" "$destination/xray"
)
core_source_fields() {
    local directory=${1%/} file
    local -a files=()
    while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$directory" -name '*.go' ! -name '*_test.go' -type f -print0)
    ((${#files[@]})) || { die '官方源码中没有可比对的配置声明。'; return; }
    awk -v root="$directory/" -f "$MANAGER_HOME/lib/core-fields.awk" "${files[@]}" | jq -Ren '[inputs|select(length>0)]|unique|sort|select(length>0)'
}
core_candidate_fields() (
    local version=$1 tmp prefix="Xray-core-${1#v}" baseline
    baseline=$(jq -r .version "$MANAGER_HOME/config/core-fields.json") || return
    if [[ $version == "$baseline" ]]; then jq .fields "$MANAGER_HOME/config/core-fields.json"; return; fi
    tmp=$(mktemp -d) || return
    trap 'rm -rf -- "$tmp"' EXIT
    core_fetch "https://github.com/XTLS/Xray-core/archive/refs/tags/$version.tar.gz" "$tmp/source.tar.gz" || return
    tar -tzf "$tmp/source.tar.gz" > "$tmp/names" || return
    awk -v prefix="$prefix/infra/conf/" '
      /^\// || /(^|\/)\.\.($|\/)/ || /\\/ {bad=1}
      index($0,prefix)==1 && /\.go$/ && /[^a-zA-Z0-9_./-]/ {bad=1}
      END {exit bad}' "$tmp/names" || {
        die '官方源码包包含不安全路径。'; return;
    }
    tar -tvzf "$tmp/source.tar.gz" --wildcards "$prefix/infra/conf/*.go" > "$tmp/types" || return
    awk 'substr($1,1,1)!="-" {bad=1} END{exit bad}' "$tmp/types" || {
        die '官方配置源码包含非普通文件。'; return;
    }
    # Limit extraction to Go configuration declarations. No upstream code runs.
    mkdir "$tmp/source" || return
    tar -xzf "$tmp/source.tar.gz" --no-same-owner --no-same-permissions -C "$tmp/source" \
        --wildcards "$prefix/infra/conf/*.go" || return
    [[ -f $tmp/source/$prefix/infra/conf/xray.go ]] || { die '官方源码包缺少配置入口。'; return; }
    core_source_fields "$tmp/source/$prefix/infra/conf"
)
core_field_report() {
    local info=$1 version fields report added removed
    version=$(jq -r .version <<< "$info")
    fields=$(core_candidate_fields "$version") || { die '无法完成新字段检查，现有核心未改变。'; return; }
    report=$(jq -n --argjson release "$info" --argjson fields "$fields" \
        --slurpfile baseline "$MANAGER_HOME/config/core-fields.json" \
        '$release+{baseline:$baseline[0].version,coverage:"infra/conf Go JSON declarations",fields:$fields,
          added:($fields-$baseline[0].fields),removed:($baseline[0].fields-$fields)}') || return
    mkdir -p "$ROOT/core-reports" || return
    jq . <<< "$report" | atomic_file "$ROOT/core-reports/$version.json" || return
    added=$(jq '.added|length' <<< "$report"); removed=$(jq '.removed|length' <<< "$report")
    if ((added)); then
        note "发现 $added 个新增 JSON 字段（相对脚本字段基线 $(jq -r .baseline <<< "$report")）："
        jq -r '.added[:20][]|"  - " + .' <<< "$report" >&2
        note '新增字段不会自动写入节点；需要脚本适配后才能在菜单中配置。'
    else note '字段检查完成：未检测到相对脚本基线新增的 JSON 字段。'; fi
    ((removed==0)) || note "另有 $removed 个字段声明移除或位置改变，现有配置将使用候选核心验证。"
    note "完整字段报告：$ROOT/core-reports/$version.json"
    note "该版本发行说明：https://github.com/XTLS/Xray-core/releases/tag/$version"
}
core_api_probe() (
    local binary=$1 work=$2 pid='' i ready=false
    mkdir "$work" "$work/runtime" && chown "root:$SERVICE_USER" "$work" && chmod 750 "$work" || return
    chown "$SERVICE_USER:$SERVICE_USER" "$work/runtime" && chmod 700 "$work/runtime" || return
    trap 'if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi' EXIT
    jq -n --arg socket "$work/runtime/api.sock" '{log:{loglevel:"none"},
      api:{tag:"probe-api",listen:$socket,services:["HandlerService","RoutingService"]},
      inbounds:[],outbounds:[{tag:"block",protocol:"blackhole"}],
      routing:{rules:[{ruleTag:"probe-initial",network:"tcp,udp",outboundTag:"block"}]}}' > "$work/config.json" || return
    chgrp "$SERVICE_USER" "$work/config.json" && chmod 640 "$work/config.json" || return
    runuser -u "$SERVICE_USER" -- env XRAY_LOCATION_ASSET="$ASSETS" "$binary" run -c "$work/config.json" > "$work/core.log" 2>&1 &
    pid=$!
    probe_api() { as_service "$binary" api "$1" --server="unix://$work/runtime/api.sock" --timeout=1 "${@:2}"; }
    probe_json() { probe_api "$@" | awk '/^[{]/{p=1}p' | jq -e .; }
    for ((i=0;i<20;i++)); do
        kill -0 "$pid" 2>/dev/null || break
        if probe_json lsi --isOnlyTags=true >/dev/null 2>&1; then ready=true; break; fi
        sleep .1
    done
    [[ $ready == true ]] || return 1
    printf '%s\n' '{"outbounds":[{"tag":"probe-out","protocol":"blackhole"}]}' > "$work/out.json"
    printf '%s\n' '{"inbounds":[{"tag":"probe-in","listen":"127.0.0.1","port":0,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1","port":9,"network":"tcp"}}]}' > "$work/in.json"
    printf '%s\n' '{"routing":{"rules":[{"ruleTag":"probe-replaced","inboundTag":["probe-in"],"outboundTag":"probe-out"}]}}' > "$work/rules.json"
    chgrp "$SERVICE_USER" "$work/"*.json && chmod 640 "$work/"*.json || return
    probe_api ado "$work/out.json" >/dev/null && probe_api adi "$work/in.json" >/dev/null || return
    probe_json lsi --isOnlyTags=true | jq -e '.inbounds|any(.tag=="probe-in")' >/dev/null || return
    probe_api adrules "$work/rules.json" >/dev/null || return
    probe_json lsrules | jq -e '([.rules[].ruleTag]==["probe-replaced"]) and (.rules[0].tag=="probe-out")' >/dev/null || return
    probe_api rmi probe-in >/dev/null && probe_api rmo probe-out >/dev/null || return
    probe_json lsi --isOnlyTags=true | jq -e '(.inbounds // [])|all(.tag!="probe-in")' >/dev/null || return
    probe_json lso | jq -e '(.outbounds // [])|all(.tag!="probe-out")' >/dev/null
)
core_runtime_matches() {
    local expected actual identity
    identity=$(process_identity)
    expected=$(jq -c '[.inbounds[].tag]|sort' "$ROOT/current/config.json") || return
    actual=$(api_json lsi --isOnlyTags=true | jq -c '[.inbounds[]?.tag]|sort') || return
    [[ $expected == "$actual" ]] || return 1
    expected=$(jq -c '[.outbounds[].tag]' "$ROOT/current/config.json") || return
    actual=$(api_json lso | jq -c '[.outbounds[]?.tag]') || return
    jq -e --argjson actual "$actual" '.-$actual|length==0' <<< "$expected" >/dev/null || return
    expected=$(jq -c '[.routing.rules[]|{ruleTag,tag:.outboundTag}]|sort_by(.ruleTag)' "$ROOT/current/config.json") || return
    actual=$(api_json lsrules | jq -c '[.rules[]|{ruleTag,tag}]|sort_by(.ruleTag)') || return
    [[ $expected == "$actual" && $(process_identity) == "$identity" ]]
}
