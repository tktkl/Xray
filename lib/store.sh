#!/usr/bin/env bash
lock_state() {
    require_root || return
    mkdir -p "$ROOT" "$ROOT/generations" "$ROOT/queue" "$ROOT/certificates" || return
    chmod 700 "$ROOT/queue" || return
    exec {LOCK_FD}>"$ROOT/lock" || return
    flock -w 30 "$LOCK_FD" || { die '另一个管理操作正在运行。'; return 1; }
    LOCKED=1
}
unlock_state() {
    if (( LOCKED )); then flock -u "$LOCK_FD"; exec {LOCK_FD}>&-; LOCKED=0; fi
}
store_init() {
    [[ -L $ROOT/current ]] && return
    local g="$ROOT/generations/g-initial"
    mkdir -p "$g/nodes" "$g/nginx"
    jq -n '{schema:1,next_id:1,dns:["localhost"],loglevel:"warning",block:{bt:true,cn:true,private:true},domains:{},certificates:{}}' > "$g/settings.json"
    printf '{}\n' > "$g/config.json"
    sync_path "$g"
    atomic_link "$g" "$ROOT/current"
    atomic_link "$g" "$ROOT/installed"
}
load_state() {
    local g=${1:-$ROOT/current}
    local -a files=()
    local f
    for f in "$g"/nodes/*.json; do [[ -e $f ]] && files+=("$f"); done
    if ((${#files[@]})); then
        STATE=$(jq -s --slurpfile settings "$g/settings.json" '{settings:$settings[0],nodes:sort_by(.id)}' "${files[@]}")
    else
        STATE=$(jq -n --slurpfile settings "$g/settings.json" '{settings:$settings[0],nodes:[]}')
    fi
}
new_generation() {
    CANDIDATE="$ROOT/generations/g-$(date +%s)-$(random_hex 8)"
    mkdir -p "$CANDIDATE/nodes" "$CANDIDATE/nginx" || return
    jq '.settings' <<< "$STATE" > "$CANDIDATE/settings.json" || return
    local id
    while IFS= read -r id; do
        jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE" > "$CANDIDATE/nodes/$id.json" || return
    done < <(jq -r '.nodes[].id' <<< "$STATE")
    render_config "$CANDIDATE" || return
    render_nginx "$CANDIDATE" || return
    chmod 750 "$ROOT" "$ROOT/generations" "$CANDIDATE" "$CANDIDATE/nginx" || return
    chgrp "$SERVICE_USER" "$ROOT" "$ROOT/generations" "$CANDIDATE" || return
    chown "root:$SERVICE_USER" "$CANDIDATE/config.json" || return
    chmod 640 "$CANDIDATE/config.json" || return
    sync_path "$CANDIDATE"
}
node_matches() {
    local selector=${1:-} matches
    if [[ -n $selector ]]; then
        if jq -e --arg s "$selector" '.nodes[]|select(.id==$s)' <<< "$STATE" >/dev/null; then
            jq --arg s "$selector" '[.nodes[]|select(.id==$s)]' <<< "$STATE"; return
        fi
        matches=$(jq --arg s "$selector" '[.nodes[]|select(.id==$s or .name==$s)]' <<< "$STATE")
        if [[ $(jq length <<< "$matches") == 0 ]]; then
            matches=$(jq --arg s "$selector" '[.nodes[]|select((.name|ascii_downcase|contains($s|ascii_downcase)) or (.id|contains($s)))]' <<< "$STATE")
        fi
    else matches=$(jq '.nodes' <<< "$STATE"); fi
    printf '%s' "$matches"
}
node_select() {
    local selector=${1:-} matches count id label
    local -a options=()
    matches=$(node_matches "$selector") || return
    count=$(jq length <<< "$matches")
    ((count > 0)) || { die '没有匹配的节点。'; return; }
    if ((count == 1)) && { [[ -n $selector ]] || [[ ! -t 0 ]]; }; then jq -r '.[0].id' <<< "$matches"; return; fi
    [[ -t 0 ]] || { die '匹配多个节点，请指定精确 ID。'; return; }
    while IFS=$'\t' read -r id label; do options+=("$id" "$label"); done < <(
        jq -r '.[]|[.id,"\(.id)  \(.name)  \(.protocol // "")  :\(.endpoint.port // "")"]|@tsv' <<< "$matches")
    menu_select '选择节点' '' "${options[@]}"
}
replace_node() { STATE=$(jq --argjson n "$1" '.nodes |= map(if .id==$n.id then $n else . end)' <<< "$STATE"); }
allocate_id() {
    printf 'n%03d' "$(jq '.settings.next_id' <<< "$STATE")"
}
transaction_log() {
    jq -n --arg old "$OLD" --arg new "$CANDIDATE" --arg phase "$1" --arg process "$EXPECTED_PROCESS" \
        '{old:$old,new:$new,phase:$phase,process:$process}' | atomic_file "$ROOT/transaction.json"
}
transaction() {
    OLD=$(readlink -f "$ROOT/current")
    EXPECTED_PROCESS=$(process_identity)
    new_generation || return
    validate_generation "$CANDIDATE" || return
    transaction_log prepared || return
    fault prepared
    if ! apply_generation "$OLD" "$CANDIDATE"; then
        note '应用失败，正在恢复最后提交的版本。'
        if reconcile_generation "$CANDIDATE" "$OLD"; then
            rm -f "$ROOT/transaction.json"
            die '操作已回滚。'
        else
            die '恢复未完成；已保留事务记录，请执行 xray recover。'
        fi
        return 1
    fi
    fault applied
    atomic_link "$CANDIDATE" "$ROOT/current" || return
    transaction_log committed || return
    fault committed
    if ! cleanup_generation "$OLD" "$CANDIDATE"; then
        note '配置已提交，旧对象清理待恢复操作完成。'
        return 1
    fi
    rm -f "$ROOT/transaction.json"
    sync_path "$ROOT"
}
recover_state() {
    if [[ -f $ROOT/data-upgrade.json ]]; then
        local backup data_running file
        backup=$(jq -r .backup "$ROOT/data-upgrade.json")
        data_running=$(jq -r .was_running "$ROOT/data-upgrade.json")
        [[ $backup == "$ROOT/data-backup" && -f $backup/geoip.dat && -f $backup/geosite.dat ]] || { die '规则数据恢复记录不合法。'; return; }
        for file in geoip.dat geosite.dat; do install -m 644 "$backup/$file" "$ASSETS/$file.restore" && mv -f "$ASSETS/$file.restore" "$ASSETS/$file" || return; done
        if [[ ${1:-} != offline && $data_running == true ]]; then systemctl restart xray-manager.service && wait_api || return; fi
        rm -f "$ROOT/data-upgrade.json"
    fi
    if [[ -f $ROOT/core-upgrade.json ]]; then
        local previous running
        previous=$(jq -r .previous "$ROOT/core-upgrade.json")
        running=$(jq -r .was_running "$ROOT/core-upgrade.json")
        [[ $previous == "$ROOT/core-backups/previous" && -f $previous ]] || { die '核心恢复记录不合法。'; return; }
        install -m 755 "$previous" "${CORE}.restore" && sync_path "${CORE}.restore" &&
            mv -f "${CORE}.restore" "$CORE" && sync_path "$(dirname -- "$CORE")" || return
        if [[ ${1:-} != offline && $running == true ]]; then systemctl restart xray-manager.service && wait_api || return; fi
        rm -f "$ROOT/core-upgrade.json"
    fi
    [[ -e $ROOT/transaction.json ]] || return 0
    local old new target current
    old=$(jq -r .old "$ROOT/transaction.json")
    new=$(jq -r .new "$ROOT/transaction.json")
    current=$(readlink -f "$ROOT/current")
    [[ $current == "$old" || $current == "$new" ]] || { die '事务与提交指针不一致，拒绝继续写入。'; return; }
    target=$current
    if [[ ${1:-} == offline ]]; then
        if service_active xray-manager.service || { [[ -e $NGINX_LOADER ]] && service_active nginx.service; }; then
            die '离线恢复要求受管服务已停止。'; return 1
        fi
        atomic_link "$target" "$ROOT/installed"
    elif [[ $(jq -r '.global // false' "$ROOT/transaction.json") == true ]]; then
        atomic_link "$target" "$ROOT/installed" || return
        if [[ $(jq -r '.was_running' "$ROOT/transaction.json") == true ]]; then
            systemctl restart xray-manager.service && wait_api || { die '全局配置恢复启动失败。'; return; }
        fi
    elif ! reconcile_generation "$([[ $target == "$old" ]] && printf '%s' "$new" || printf '%s' "$old")" "$target"; then
        die '运行状态恢复失败，保留事务记录。'; return 1
    fi
    rm -f "$ROOT/transaction.json"
    sync_path "$ROOT"
}
global_transaction() {
    local running=false
    OLD=$(readlink -f "$ROOT/current")
    EXPECTED_PROCESS=$(process_identity)
    service_active xray-manager.service && running=true
    new_generation && validate_generation "$CANDIDATE" || return
    jq -n --arg old "$OLD" --arg new "$CANDIDATE" --argjson running "$running" \
        '{old:$old,new:$new,phase:"prepared",global:true,was_running:$running}' | atomic_file "$ROOT/transaction.json"
    fault prepared
    atomic_link "$CANDIDATE" "$ROOT/installed" || return
    if [[ $running == true ]]; then
        if ! systemctl restart xray-manager.service || ! wait_api; then
            atomic_link "$OLD" "$ROOT/installed"
            if systemctl restart xray-manager.service && wait_api; then rm -f "$ROOT/transaction.json"; fi
            die '全局配置应用失败，已尝试恢复旧版本。'; return 1
        fi
    fi
    fault applied
    atomic_link "$CANDIDATE" "$ROOT/current" || return
    fault committed
    rm -f "$ROOT/transaction.json"
    sync_path "$ROOT"
}
