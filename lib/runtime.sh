#!/usr/bin/env bash
api() { "$CORE" api "$1" --server="unix://$SOCKET" --timeout=5 "${@:2}"; }
api_json() {
    local result
    result=$(api "$@") || return
    awk '/^[{]/{p=1}p' <<< "$result" | jq .
}
core_unchanged() {
    [[ $(process_identity) == "$EXPECTED_PROCESS" ]] || { die '核心进程在事务期间发生变化，请恢复后重试。'; return; }
}
snapshot_runtime() {
    LIVE_IN=$(api_json lsi --isOnlyTags=true | jq -c '[.inbounds[]?.tag]') || return
    LIVE_OUT=$(api_json lso | jq -c '[.outbounds[]?.tag]') || return
}
tag_present() { jq -e --arg tag "$1" 'index($tag)!=null' <<< "$2" >/dev/null; }
api_add_checked() {
    local type=$1 file=$2 tag=$3 listing field live
    if api "$type" "$file" >/dev/null 2>&1; then return; fi
    [[ $type == adi ]] && { listing=lsi; field=inbounds; } || { listing=lso; field=outbounds; }
    live=$(api_json "$listing" | jq -c --arg f "$field" '[.[$f][]?.tag]') || return
    tag_present "$tag" "$live"
}
api_remove_checked() {
    local type=$1 tag=$2 listing field live
    if api "$type" "$tag" >/dev/null 2>&1; then return; fi
    [[ $type == rmi ]] && { listing=lsi; field=inbounds; } || { listing=lso; field=outbounds; }
    live=$(api_json "$listing" | jq -c --arg f "$field" '[.[$f][]?.tag]') || return
    ! tag_present "$tag" "$live"
}
runtime_to() {
    local from=$1 to=$2 tag oldtag id object tmp route_expected route_live
    snapshot_runtime || return
    tmp=$(mktemp -d "$ROOT/api.XXXXXX")
    while IFS= read -r object; do
        tag=$(jq -r .tag <<< "$object")
        if ! tag_present "$tag" "$LIVE_OUT"; then
            jq -n --argjson o "$object" '{outbounds:[$o]}' > "$tmp/object.json"
            api_add_checked ado "$tmp/object.json" "$tag" || { rm -rf "$tmp"; return 1; }
        fi
    done < <(jq -c '.outbounds[]' "$to/config.json")
    fault outbounds
    core_unchanged || { rm -rf "$tmp"; return 1; }
    # The definitive candidate table is installed after listeners below. A new
    # inbound is fail-closed under the existing permanent default-deny rule.
    while IFS= read -r object; do
        tag=$(jq -r .tag <<< "$object")
        if ! tag_present "$tag" "$LIVE_IN"; then
            id=${tag%-r*}
            while IFS= read -r oldtag; do
                [[ $oldtag == "$id"-r* ]] || continue
                api_remove_checked rmi "$oldtag" || { rm -rf "$tmp"; return 1; }
            done < <(jq -r '.[]' <<< "$LIVE_IN")
            jq -n --argjson i "$object" '{inbounds:[$i]}' > "$tmp/object.json"
            api_add_checked adi "$tmp/object.json" "$tag" || { rm -rf "$tmp"; return 1; }
        fi
    done < <(jq -c '.inbounds[]' "$to/config.json")
    fault inbounds
    core_unchanged || { rm -rf "$tmp"; return 1; }
    jq '{routing}' "$to/config.json" > "$tmp/rules.json"
        if ! api adrules "$tmp/rules.json" >/dev/null 2>&1; then
        route_expected=$(jq -c '[.routing.rules[]|{ruleTag,tag:.outboundTag}]|sort_by(.ruleTag)' "$to/config.json")
        route_live=$(api_json lsrules | jq -c '[.rules[]|{ruleTag,tag}]|sort_by(.ruleTag)') || { rm -rf "$tmp"; return 1; }
        [[ $route_expected == "$route_live" ]] || { rm -rf "$tmp"; return 1; }
    fi
    fault routes
    snapshot_runtime || { rm -rf "$tmp"; return 1; }
    while IFS= read -r tag; do
        tag_present "$tag" "$LIVE_IN" || { rm -rf "$tmp"; return 1; }
    done < <(jq -r '.inbounds[].tag' "$to/config.json")
    core_unchanged || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}
cleanup_generation() {
    local from=$1 to=$2 tag desired
    if service_active xray-manager.service; then
        core_unchanged || return
        snapshot_runtime || return
        desired=$(jq -c '[.inbounds[].tag]' "$to/config.json")
        while IFS= read -r tag; do
            [[ $tag == in-n*-r* ]] || continue
            if ! tag_present "$tag" "$desired"; then api_remove_checked rmi "$tag" || return; fi
        done < <(jq -r '.[]' <<< "$LIVE_IN")
        desired=$(jq -c '[.outbounds[].tag]' "$to/config.json")
        while IFS= read -r tag; do
            [[ $tag == out-n*-r* ]] || continue
            if ! tag_present "$tag" "$desired"; then api_remove_checked rmo "$tag" || return; fi
        done < <(jq -r '.[]' <<< "$LIVE_OUT")
    fi
}
apply_generation() {
    local from=$1 to=$2
    if service_active xray-manager.service; then runtime_to "$from" "$to" || return; fi
    nginx_apply "$to" || return
    fault nginx
    core_unchanged
}
reconcile_generation() {
    local from=$1 to=$2
    EXPECTED_PROCESS=$(process_identity)
    if service_active xray-manager.service; then runtime_to "$from" "$to" || return; fi
    nginx_apply "$to" || return
    cleanup_generation "$from" "$to"
}
validate_generation() {
    local g=$1
    jq -e 'type=="object" and (.schema==1) and (.next_id|type=="number")' "$g/settings.json" >/dev/null || return
    validate_collisions "$g" || return
    as_service "$CORE" run -test -c "$g/config.json" >"$ROOT/validation-error.log" 2>&1 || { note "Xray 配置验证失败，诊断位于 $ROOT/validation-error.log"; return 1; }
    if [[ -e $NGINX_LOADER ]] || find "$g/nginx" -name '*.conf' -print -quit | read -r _; then nginx_shadow_test "$g" || return; fi
}
validate_collisions() {
    local g=$1 old="$ROOT/current/config.json" protocol port tag listen existing managed=0
    jq -e '
      [.inbounds[]|{listen,port,net:(if .streamSettings.network=="kcp" or .streamSettings.network=="hysteria" then "udp" else "tcp" end)}] as $ports |
      ($ports|length)==($ports|unique|length) and
      ([.inbounds[].tag]|length)==([.inbounds[].tag]|unique|length) and
      ([.outbounds[].tag]|length)==([.outbounds[].tag]|unique|length)
    ' "$g/config.json" >/dev/null || { die '入口端口或标签冲突。'; return; }
    # Prefix overlap is rejected conservatively even across different transports.
    jq -e '[.nodes[]|select(.security=="nginx") ] as $n |
      all(range(0;$n|length); . as $i | all(range($i+1;$n|length); . as $j |
      ($n[$i].endpoint.domain!=$n[$j].endpoint.domain or $n[$i].endpoint.port!=$n[$j].endpoint.port or
      (($n[$i].endpoint.path|startswith($n[$j].endpoint.path))|not) and (($n[$j].endpoint.path|startswith($n[$i].endpoint.path))|not))))
    ' <<< "$STATE" >/dev/null || { die '同域名同端口的代理路径重叠。'; return; }
    jq -e '(([.settings.domains|keys[]] | length)>0) as $has_nginx |
      ([.nodes[]|select(.security=="nginx")|.endpoint.port]+(if $has_nginx then [80,443] else [] end)|unique) as $front |
      all(.nodes[]; (.network=="kcp" or .network=="hysteria" or .security=="nginx" or .manual_tls) or (.endpoint.port as $p|$front|index($p)|not))' <<< "$STATE" >/dev/null || { die '直接入口与 Nginx 公网监听端口冲突。'; return; }
    while IFS=$'\t' read -r protocol port tag listen; do
        existing=$(ss -H -ln"$([[ $protocol == udp ]] && echo u || echo t)" "sport = :$port")
        [[ -z $existing ]] && continue
        managed=0
        if service_active xray-manager.service && jq -e --argjson p "$port" '.inbounds[]?|select(.port==$p)' "$old" >/dev/null; then managed=1; fi
        ((managed)) || { die "端口 $port/$protocol 已被占用。"; return; }
    done < <(jq -r '.inbounds[]|[(if .streamSettings.network=="kcp" or .streamSettings.network=="hysteria" then "udp" else "tcp" end),.port,.tag,.listen]|@tsv' "$g/config.json")
}
