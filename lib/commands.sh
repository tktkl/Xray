#!/usr/bin/env bash
help_text() {
    printf 'Xray 独立管理脚本 %s\n' "$VERSION"
    cat <<'EOF'
用法：xray [命令] [参数]；不带参数打开菜单。
交互选项按序号选择；主菜单 0 退出，子菜单 0 上一步。原有带参数命令保持可用。

节点：
  a, add [协议] [参数...|auto] [--name 名称] [--address 对外地址]
  c, change [节点] [修改项] [值...]
  d, del, rm [节点]                dd, ddel 节点...
  i, info [节点]                  list
  url, qr [节点]                  client, genc [节点] [current|legacy]
  legacy 仅切换客户端 JSON 字段格式，不设置版本上下限。
  ob [节点] [direct|分享链接]       c [节点] outbound [direct|分享链接]

协议参数（auto 自动生成；TLS 协议需要 Cloudflare 凭据）：
  reality [端口] [UUID] [SNI]       tcp/kcp [端口] [UUID] [none]
  ws/grpc/vws/vgrpc/xhttp/tws/tgrpc [域名] [UUID或密码] [/路径]
  ss [端口] [密码] [加密方式]       hy2 [端口] [密码] --domain 域名
  socks [端口] [用户名] [密码]      door [端口] [目标地址] [目标端口]

修改项（也可直接作为命令：xray port n001 24443）：
  port / id / passwd / method / key / sni / host / path / seed / type
  new [协议] [参数...]              full [协议参数...]
  web [伪装网站域名|static]          address [对外地址]

证书：cert setup [--credentials FILE] [--email EMAIL]
      cert issue 域名 | cert list | cert renew [域名] | cert deploy [域名]
      cert delete 域名 | domain delete 域名（均需无引用）

管理：start / stop / restart [nginx]；s, status；t, test
      recover [--offline]；fix [节点]；fix-all；fix-nginx；fix-config.json
      dns [none|11|88|google|cloudflare|family|set DNS]
      log [debug|info|warning|error|none|del]；logerr
      u, update [core|sh|dat|nginx|certbot] [版本]；U, update.sh [版本]
      update sh 版本                 下载已校验的公开 Release 更新脚本
      install；reinstall；un, uninstall；bbr

工具：v, version；ip；get-port；ss2022 [加密方式]；pbk
      gen [协议] [参数...]；no-auto-tls [协议] [参数...]
      debug [节点]（脱敏）；bin [核心参数...]；xapi [API参数...]
      api / x25519 / tls / run / uuid [核心参数...]

普通节点修改仅影响当前节点。核心更新、DNS、fix-all、restart 为全局操作。
动态端口已由上游移除。Caddy 命令请改用 nginx / fix-nginx / cert。
EOF
}
context() {
    local dependency
    require_root || return
    for dependency in jq openssl flock ss runuser sync; do need "$dependency" || return; done
    [[ -x $CORE ]] || { die '核心未安装，请先执行 install.sh。'; return; }
    id "$SERVICE_USER" >/dev/null 2>&1 || { die '缺少服务用户，请先安装。'; return; }
    [[ $ROOT =~ ^/[a-zA-Z0-9_./-]+$ && $ROOT != / && $ROOT != *..* ]] || { die '不安全的状态目录。'; return; }
    mkdir -p "$ROOT/logs"
    chown "$SERVICE_USER:$SERVICE_USER" "$ROOT/logs"
    lock_state || return
    store_init && load_state || { unlock_state; return 1; }
    unlock_state
}
write_begin() { lock_state && recover_state && load_state; }
prepare_node_resources() {
    local security domain
    security=$(jq -r .security <<< "$NODE"); domain=$(jq -r .endpoint.domain <<< "$NODE")
    if [[ $security == nginx || $security == tls ]]; then cert_ensure "$domain" || return; fi
    if [[ $security == nginx ]]; then ensure_component nginx || return; fi
}
attach_domain() {
    local domain
    if [[ $(jq -r .security <<< "$NODE") == nginx ]]; then
        domain=$(jq -r .endpoint.domain <<< "$NODE")
        STATE=$(jq --arg d "$domain" '.settings.domains[$d] //= {web:""}' <<< "$STATE")
    fi
}
command_add() {
    local protocol=${1:-} id backend
    if [[ -z $protocol ]]; then
        select_and_build_node '{}' || return
    else
        shift
        build_node "$protocol" '{}' "$@" || return
    fi
    prepare_node_resources || return
    write_begin || return
    id=$(allocate_id); backend=$(free_port)
    NODE=$(jq --arg id "$id" --argjson backend "$backend" '.id=$id|.name=(if .name=="" then $id else .name end)|.backend.port=$backend' <<< "$NODE")
    attach_domain
    STATE=$(jq --argjson n "$NODE" '.nodes+=[$n]|.settings.next_id+=1' <<< "$STATE")
    transaction || { unlock_state; return 1; }
    unlock_state
    printf '已添加 %s\n' "$id"
    node_info "$NODE"
}
node_info() {
    local n=$1
    jq -r '"ID: \(.id)  名称: \(.name)\n协议: \(.protocol)  对外: \(.endpoint.address):\(.endpoint.port)\n出口: \(.outbound.protocol)\nSNI: \(.sni)\n后端: 127.0.0.1:\(.backend.port)"' <<< "$n"
    share_uri "$n" || true
}
command_list() {
    if [[ $(jq '.nodes|length' <<< "$STATE") == 0 ]]; then note '暂无节点，请选择添加节点，或运行 xray a。'; return; fi
    jq -r '.nodes[]|[.id,.name,.protocol,(.endpoint.address+":"+(.endpoint.port|tostring)),.outbound.protocol]|@tsv' <<< "$STATE"
}
select_change_option() {
    local n=$1 kind security network
    kind=$(jq -r .kind <<< "$n"); security=$(jq -r .security <<< "$n"); network=$(jq -r .network <<< "$n")
    local -a options=(port '修改公网端口' new '切换入口协议' outbound '设置节点出口' address '修改对外地址')
    case $kind in
        vless|vmess) options+=(id '修改 UUID');;
        shadowsocks|trojan|hysteria|socks) options+=(passwd '修改密码');;
    esac
    [[ $security != reality ]] || options+=(sni '修改 REALITY SNI' key '修改 REALITY 密钥')
    [[ $kind != shadowsocks ]] || options+=(method '修改 SS 加密方式（同时生成新密码）')
    [[ $kind != socks ]] || options+=(username '修改 SOCKS 用户名')
    [[ $kind != dokodemo-door ]] || options+=(dda '修改转发目标地址' ddp '修改转发目标端口')
    if [[ $security == nginx || $security == tls ]]; then options+=(host '修改证书域名'); fi
    if [[ $network =~ ^(ws|grpc|xhttp)$ ]]; then options+=(path '修改路径／gRPC 服务名'); fi
    [[ $security != nginx ]] || options+=(web '修改域名共享的伪装网站')
    [[ $network != kcp ]] || options+=(seed '修改 mKCP seed')
    options+=(full '重建当前节点')
    menu_select "修改节点 $(jq -r '.id+"（"+.protocol+"）"' <<< "$n")" port "${options[@]}"
}
select_outbound() {
    local value result
    while :; do
        value=$(menu_select '设置节点出口' direct direct '本机直连' import '粘贴上游分享链接（SS／VLESS／VMess／Trojan／SOCKS5／HTTP）') || return
        if [[ $value == import ]]; then
            if value=$(prompt_step '请粘贴完整的出口分享链接'); then :
            else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
        fi
        printf '%s' "$value"; return
    done
}
select_website() {
    local value result
    while :; do
        value=$(menu_select '选择域名共享的伪装网站' static static '本地静态网站' proxy '反向代理指定 HTTPS 网站') || return
        if [[ $value == proxy ]]; then
            if value=$(prompt_step '伪装网站域名（不含 https:// 和路径）'); then :
            else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
        fi
        printf '%s' "$value"; return
    done
}
command_change() {
    local selector=${1:-} option=${2:-} id old value method public private domain args protocol
    (($#==0)) || shift
    (($#==0)) || shift
    id=$(node_select "$selector") || return
    old=$(jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE")
    NODE=$old
    if [[ -z $option ]]; then option=$(select_change_option "$old") || return; fi
    value=$(auto_value "${1:-}")
    case $option in
        new)
            if (($#==0)); then
                select_and_build_node "$old" || return
            else
                protocol=$1; shift
                if (($#==0)); then
                    case $(canonical_protocol "$protocol") in
                        *-TLS) set -- "$(jq -r .endpoint.domain <<< "$old")";;
                        *) set -- "$(jq -r .endpoint.port <<< "$old")";;
                    esac
                    set -- "$@" --address "$(jq -r .endpoint.address <<< "$old")"
                fi
                build_node "$protocol" "$old" "$@" || return
            fi
            NODE=$(jq --argjson old "$old" '.id=$old.id|.name=(if .name=="" then $old.name else .name end)|.outbound=$old.outbound|.outbound_revision=$old.outbound_revision|.inbound_revision=($old.inbound_revision+1)|.backend=$old.backend' <<< "$NODE");;
        full)
            if (($#)); then
                protocol=$(jq -r .protocol <<< "$old")
                build_node "$protocol" "$old" "$@" || return
                NODE=$(jq --argjson old "$old" '.id=$old.id|.name=$old.name|.outbound=$old.outbound|.outbound_revision=$old.outbound_revision|.inbound_revision=($old.inbound_revision+1)|.backend=$old.backend' <<< "$NODE")
            else NODE=$(jq '.inbound_revision+=1' <<< "$old"); fi;;
        ob|outbound)
            if [[ -z $value ]]; then value=$(select_outbound) || return; fi
            if [[ $value == direct ]]; then value='{"protocol":"freedom","settings":{}}'
            else value=$(outbound_from_uri "$value") || return; fi
            NODE=$(jq --argjson o "$value" '.outbound=$o|.outbound_revision+=1' <<< "$NODE");;
        port)
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step '新的公网端口（auto 随机分配）' auto) || return; value=$(auto_value "$value"); fi
            value=${value:-$(free_port)}; valid_port "$value" || { die '无效端口。'; return; }
            value=$((10#$value))
            NODE=$(jq --argjson p "$value" '.endpoint.port=$p|.inbound_revision+=(if .security=="nginx" then 0 else 1 end)' <<< "$NODE");;
        id|uuid)
            [[ $(jq -r .kind <<< "$NODE") =~ ^(vless|vmess)$ ]] || { die '当前协议不使用 UUID。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step '新 UUID（auto 自动生成）' auto) || return; value=$(auto_value "$value"); fi
            value=${value:-$(uuid)}; valid_uuid "$value" || { die '无效 UUID。'; return; }
            NODE=$(jq --arg v "$value" '.credentials.id=$v|.inbound_revision+=1' <<< "$NODE");;
        passwd|pass|password)
            [[ $(jq -r .kind <<< "$NODE") =~ ^(shadowsocks|trojan|hysteria|socks)$ ]] || { die '当前协议不使用密码。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step '新密码（auto 自动生成）' auto) || return; value=$(auto_value "$value"); fi
            method=$(jq -r .credentials.method <<< "$NODE")
            if [[ $(jq -r .kind <<< "$NODE") == shadowsocks ]]; then value=${value:-$(ss_password "$method")}; validate_ss "$method" "$value" || return
            else value=${value:-$(random_hex 24)}; fi
            nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.password=$v|.inbound_revision+=1' <<< "$NODE");;
        method|ssm|ss-method|ss_method)
            [[ $(jq -r .kind <<< "$NODE") == shadowsocks ]] || { die '只有 SS 支持 method。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(select_ss_method) || return; fi
            value=${value:-2022-blake3-aes-128-gcm}
            args=$(ss_password "$value"); validate_ss "$value" "$args" || return
            NODE=$(jq --arg m "$value" --arg p "$args" '.credentials.method=$m|.credentials.password=$p|.inbound_revision+=1' <<< "$NODE");;
        key|publickey|privatekey)
            [[ $(jq -r .security <<< "$NODE") == reality ]] || { die '只有 REALITY 支持此密钥修改。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step 'REALITY 私钥（auto 生成新密钥）' auto) || return; value=$(auto_value "$value"); fi
            if [[ -n $value ]]; then args=$("$CORE" x25519 -i "$value") || return
            else args=$("$CORE" x25519) || return; fi
            private=$(awk -F ': ' '/^Private[Kk]ey:/{print $2}' <<< "$args")
            public=$(awk -F ': ' '/^(Public[Kk]ey|Password)/{print $2}' <<< "$args")
            [[ -n $private && -n $public ]] || return 1
            [[ -z ${2:-} || $2 == "$public" ]] || { die '给定公钥与私钥不匹配。'; return; }
            NODE=$(jq --arg private "$private" --arg public "$public" '.credentials.private_key=$private|.credentials.public_key=$public|.inbound_revision+=1' <<< "$NODE");;
        sni|servername|servernames)
            [[ $(jq -r .security <<< "$NODE") == reality ]] || { die '此命令只修改 REALITY SNI。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(select_reality_sni) || return; value=$(auto_value "$value"); fi
            value=${value:-$(choose_reality)}; probe_reality "$value" || { die 'SNI 检测失败。'; return; }
            NODE=$(jq --arg v "$value" '.sni=$v|.inbound_revision+=1' <<< "$NODE");;
        host)
            [[ -n $(jq -r .endpoint.domain <<< "$NODE") ]] || { die '此节点不使用证书域名。'; return; }
            if [[ -z $value ]]; then value=$(prompt_step '新域名') || return; fi
            value=${value,,}
            valid_domain "$value" || { die '无效域名。'; return; }
            NODE=$(jq --arg v "$value" '.endpoint.domain=$v|.endpoint.address=$v|.inbound_revision+=1' <<< "$NODE");;
        address)
            if [[ -z $value ]]; then value=$(prompt_step '对外地址') || return; fi
            valid_address "$value" || return
            NODE=$(jq --arg v "$value" '.endpoint.address=$v' <<< "$NODE");;
        path)
            [[ $(jq -r .network <<< "$NODE") =~ ^(ws|grpc|xhttp)$ ]] || { die '此协议没有反代路径。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step '新路径／gRPC 服务名（auto 自动生成）' auto) || return; value=$(auto_value "$value"); fi
            value=${value:-/$(random_hex 12)}; valid_path "$value" && [[ $value != / ]] || { die '无效路径。'; return; }
            NODE=$(jq --arg v "$value" '.endpoint.path=$v|.inbound_revision+=1' <<< "$NODE");;
        seed|kcpseed|kcp-seed|kcp_seed)
            [[ $(jq -r .network <<< "$NODE") == kcp ]] || { die '此协议不支持 seed。'; return; }
            if (($#==0)) && [[ -t 0 ]]; then value=$(prompt_step '新的 mKCP seed（auto 自动生成）' auto) || return; value=$(auto_value "$value"); fi
            value=${value:-$(random_hex 12)}; nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.seed=$v|.kcp_compat="legacy"|.inbound_revision+=1' <<< "$NODE");;
        type|header|header-type|header_type)
            [[ $(jq -r .network <<< "$NODE") =~ ^(tcp|kcp)$ ]] || { die '此协议不支持 header。'; return; }
            [[ ${value:-none} == none ]] || { die '此核心不支持所请求的旧式 header。'; return; }
            NODE=$(jq '.credentials.header="none"|.inbound_revision+=1' <<< "$NODE");;
        username)
            [[ $(jq -r .kind <<< "$NODE") == socks ]] || return 1
            if [[ -z $value ]]; then value=$(prompt_step '用户名') || return; fi
            nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.username=$v|.inbound_revision+=1' <<< "$NODE");;
        dda|door-addr|door_addr)
            [[ $(jq -r .kind <<< "$NODE") == dokodemo-door ]] || return 1
            if [[ -z $value ]]; then value=$(prompt_step '转发目标地址') || return; fi
            valid_address "$value" || return
            NODE=$(jq --arg v "$value" '.remote.address=$v|.inbound_revision+=1' <<< "$NODE");;
        ddp|door-port|door_port)
            [[ $(jq -r .kind <<< "$NODE") == dokodemo-door ]] || return 1
            if [[ -z $value ]]; then value=$(prompt_step '转发目标端口') || return; fi
            valid_port "$value" || { die '无效目标端口。'; return; }
            value=$((10#$value))
            NODE=$(jq --argjson v "$value" '.remote.port=$v|.inbound_revision+=1' <<< "$NODE");;
        web|proxy-site)
            domain=$(jq -r .endpoint.domain <<< "$NODE")
            [[ $(jq -r .security <<< "$NODE") == nginx ]] || { die '此节点没有 Nginx 站点。'; return; }
            if [[ -z $value ]]; then value=$(select_website) || return; fi
            [[ $value == static ]] && value=''
            [[ -z $value ]] || valid_domain "$value" || { die '伪装目标必须是固定域名。'; return; }
            note "此操作修改域名共享网站：$domain"
            ;;
        dp|dyp|dynamic|dynamicport|dynamic-port) die '上游已移除动态端口功能。'; return 1;;
        *) die '未知修改项。'; return 1;;
    esac
    prepare_node_resources || return
    write_begin || return
    [[ $(jq -cS --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE") == "$(jq -cS . <<< "$old")" ]] || { unlock_state; die '节点已被其他操作修改，请重试。'; return; }
    attach_domain
    if [[ $option == web || $option == proxy-site ]]; then STATE=$(jq --arg d "$domain" --arg v "$value" '.settings.domains[$d].web=$v' <<< "$STATE"); fi
    replace_node "$NODE"
    transaction || { unlock_state; return 1; }
    unlock_state
    node_info "$NODE"
}
command_delete() {
    local selector id
    local -a ids=()
    if (($#==0)); then id=$(node_select '') || return; ids+=("$id")
    else for selector in "$@"; do id=$(node_select "$selector") || return; ids+=("$id"); done; fi
    write_begin || return
    for id in "${ids[@]}"; do STATE=$(jq --arg id "$id" '.nodes|=map(select(.id!=$id))' <<< "$STATE"); done
    transaction || { unlock_state; return 1; }
    unlock_state
}
command_dns() {
    local value=${1:-} dns
    if [[ -z $value ]]; then
        value=$(menu_select '选择全局 DNS（影响所有节点）' none \
            none '使用服务器 DNS' 11 '1.1.1.1' 88 '8.8.8.8' google 'Google DoH' \
            cloudflare 'Cloudflare DoH' family 'Cloudflare 家庭过滤 DoH' set '手动输入 DNS 地址') || return
    fi
    case $value in
        none) dns='["localhost"]';;
        11|1111) dns='["1.1.1.1"]';;
        88|8888) dns='["8.8.8.8"]';;
        gg|google) dns='["https+local://dns.google/dns-query"]';;
        cf|cloudflare) dns='["https+local://cloudflare-dns.com/dns-query"]';;
        nosex|family) dns='["https+local://family.cloudflare-dns.com/dns-query"]';;
        set) value=${2:-}; if [[ -z $value ]]; then value=$(prompt_step 'DNS 地址') || return; fi
            nonempty "$value" || return; dns=$(jq -n --arg d "$value" '[$d]');;
        *) die '未知 DNS 选项。'; return 1;;
    esac
    note 'DNS 修改是全局操作；将更新所有节点使用的解析设置。'
    systemctl start xray-manager-recover.service || return
    write_begin || return
    STATE=$(jq --argjson dns "$dns" '.settings.dns=$dns' <<< "$STATE")
    global_transaction || { unlock_state; return 1; }
    unlock_state
}
command_log() {
    local target=$1 value=${2:-}
    # Log entries live in a service-writable directory. Never follow them as root.
    if [[ -z $value ]]; then as_service tail -F -- "$ROOT/logs/$([[ $target == log ]] && echo access || echo error).log"; return; fi
    if [[ $value == del ]]; then
        as_service truncate -s 0 -- "$ROOT/logs/access.log" "$ROOT/logs/error.log"
        return
    fi
    [[ $value =~ ^(debug|info|warning|error|none)$ ]] || { die '无效日志级别。'; return; }
    note '日志设置是全局操作。'
    systemctl start xray-manager-recover.service || return
    write_begin || return
    STATE=$(jq --arg v "$value" '.settings.loglevel=$v' <<< "$STATE")
    global_transaction || { unlock_state; return 1; }
    unlock_state
}
command_remove_resource() {
    local type=$1 domain=${2:-}
    valid_domain "$domain" || { die '需要有效域名。'; return; }
    write_begin || return
    if jq -e --arg d "$domain" '.nodes[]|select(.endpoint.domain==$d)' <<< "$STATE" >/dev/null; then unlock_state; die '域名仍被节点引用。'; return; fi
    if [[ $type == domain ]]; then
        STATE=$(jq --arg d "$domain" 'del(.settings.domains[$d])' <<< "$STATE")
        transaction || { unlock_state; return 1; }
        unlock_state
    else
        if jq -e --arg d "$domain" '.settings.domains|has($d)' <<< "$STATE" >/dev/null; then unlock_state; die '证书仍被 Nginx 网站引用。'; return; fi
        [[ -e $ROOT/managed-certificates/$domain.json ]] || { unlock_state; die '非受管证书。'; return; }
        STATE=$(jq --arg d "$domain" 'del(.settings.certificates[$d])' <<< "$STATE")
        transaction || { unlock_state; return 1; }
        unlock_state
        certbot delete --non-interactive --cert-name "xray-$domain" || return
        rm -f "$ROOT/managed-certificates/$domain.json" "$ROOT/queue/$domain.json" "$ROOT/queue/$domain.error"
    fi
}
menu_run() {
    local entry="$MANAGER_HOME/bin/xray" menu_home=$MANAGER_HOME
    case $MANAGER_HOME in
        /usr/local/lib/xray-manager|/usr/local/lib/xray-manager/releases/*) entry=$MANAGER_ENTRYPOINT; menu_home='';;
    esac
    # Keep errexit active inside mutations, even when the caller handles Back.
    XRAY_MANAGER_HOME="$menu_home" bash "$entry" "$@"
}
menu_change() {
    local selector=${1:-} id node option result count
    while :; do
        load_state
        count=$(node_matches "$selector" | jq length) || return
        id=$(node_select "$selector") || return
        while :; do
            load_state
            if node=$(jq -ce --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE"); then :
            else note '节点已删除，请重新选择。'; break; fi
            if option=$(select_change_option "$node"); then :
            else
                result=$?
                if [[ $result == 125 ]] && { [[ -z $selector ]] || ((count>1)); }; then break; fi
                return "$result"
            fi
            if menu_run "$option" "$id"; then return
            else result=$?; [[ $result == 125 ]] || return "$result"; fi
        done
    done
}
menu_node_action() {
    local command=$1 id result
    while :; do
        load_state
        id=$(node_select '') || return
        if menu_run "$command" "$id"; then return
        else result=$?; [[ $result == 125 ]] || return "$result"; fi
    done
}
menu_share() {
    local choice result id
    while :; do
        choice=$(menu_select '选择导出方式' url url '分享链接' qr '终端二维码' client 'Xray 客户端 JSON' legacy 'Xray 客户端 JSON（旧式字段）') || return
        set -- "$choice"
        if [[ $choice == legacy ]]; then
            load_state
            if id=$(node_select ''); then set -- client "$id" legacy
            else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
        fi
        if menu_run "$@"; then return
        else result=$?; [[ $result == 125 ]] || return "$result"; fi
    done
}
menu_dns() {
    local choice address result
    while :; do
        choice=$(menu_select '选择全局 DNS（影响所有节点）' none \
            none '使用服务器 DNS' 11 '1.1.1.1' 88 '8.8.8.8' google 'Google DoH' \
            cloudflare 'Cloudflare DoH' family 'Cloudflare 家庭过滤 DoH' set '手动输入 DNS 地址') || return
        set -- dns "$choice"
        if [[ $choice == set ]]; then
            if address=$(prompt_step 'DNS 地址'); then :
            else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
            set -- "$@" "$address"
        fi
        menu_run "$@"; return
    done
}
menu_service() {
    local choice
    choice=$(menu_select '服务管理（停止／重启会影响整个服务）' status \
        status '查看服务状态' start '启动 Xray' stop '停止 Xray' restart '重启 Xray' \
        nginx-start '启动 Nginx' nginx-stop '停止 Nginx' nginx-restart '重启 Nginx') || return
    case $choice in nginx-*) menu_run "${choice#nginx-}" nginx;; *) menu_run "$choice";; esac
}
menu_cert() {
    local choice domain result
    while :; do
        choice=$(menu_select '证书与域名管理' list list '查看证书状态' setup '配置 Cloudflare Token 与邮箱' \
            issue '签发域名证书' renew '检查并续期证书' deploy '重试部署已签发证书' \
            delete '删除无引用的受管证书' domain '删除无引用的域名网站') || return
        set -- cert "$choice"
        case $choice in
            renew|deploy)
                if domain=$(prompt_step '证书域名（all 表示全部）' all); then :
                else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
                [[ $domain != all ]] || domain=''
                set -- "$@" "$domain";;
            issue|delete|domain)
                if domain=$(prompt_step '域名'); then :
                else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
                if [[ $choice == domain ]]; then set -- domain delete "$domain"; else set -- "$@" "$domain"; fi;;
        esac
        if menu_run "$@"; then return
        else result=$?; [[ $result == 125 ]] || return "$result"; fi
    done
}
menu_log() {
    local choice level result
    while :; do
        choice=$(menu_select '日志管理' access access '查看访问日志（Ctrl+C 退出）' error '查看错误日志（Ctrl+C 退出）' \
            level '修改全局日志级别' clear '清空访问与错误日志') || return
        case $choice in
            access) set -- log;; error) set -- logerr;; clear) set -- log del;;
            level)
                if level=$(menu_select '全局日志级别（影响所有节点）' warning debug '调试 debug' info '信息 info' \
                    warning '警告 warning' error '错误 error' none '关闭日志'); then :
                else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
                set -- log "$level";;
        esac
        menu_run "$@"; return
    done
}
menu_update() {
    local choice version result
    while :; do
        choice=$(menu_select '选择更新组件' core core 'Xray 核心（影响所有节点）' sh '管理脚本' dat '规则数据' \
            nginx 'Nginx' certbot 'Certbot') || return
        set -- update "$choice"
        if [[ $choice == sh ]]; then
            if version=$(prompt_step "已发布的脚本版本（例如 v$VERSION）"); then :
            else result=$?; [[ $result == 125 ]] && continue; return "$result"; fi
            set -- "$@" "$version"
        fi
        menu_run "$@"; return
    done
}
menu_repair() {
    local choice result
    while :; do
        choice=$(menu_select '配置检查与恢复' test test '检查当前配置' recover '恢复未完成的操作' \
            fix '重建指定节点' fix-nginx '重建 Nginx 配置' fix-all '重建全部节点（影响所有节点）') || return
        if menu_run "$choice"; then return
        else result=$?; [[ $result == 125 ]] || return "$result"; fi
    done
}
menu() {
    local choice result
    [[ -t 0 ]] || { help_text; return; }
    while :; do
        choice=$(menu_select --exit 'Xray 管理菜单' a \
            a '添加节点' c '修改节点' list '查看节点列表' d '删除节点' status '运行状态' help '帮助' \
            ob '设置节点出口' share '导出分享链接／二维码／客户端配置' service '服务管理' cert '证书与域名管理' \
            dns '全局 DNS 设置' logs '日志管理' update '更新组件' repair '配置检查与恢复') || {
                result=$?; if [[ $result == 125 || $result == 130 ]]; then return 0; fi; return "$result";
            }
        if menu_run "$choice"; then :
        else
            result=$?
            [[ $result != 130 ]] || return 0
            if [[ $result != 125 ]]; then note "操作未完成（退出码 $result），已返回主菜单。"; fi
        fi
    done
}
main() {
    local command=${1:-menu} id node target value
    (($#==0)) || shift
    case $command in
        h|help|--help) help_text; return;;
        v|ver|version) printf 'Xray manager %s\n' "$VERSION"; [[ ! -x $CORE ]] || "$CORE" version; return;;
        install) install_manager "$@"; return;;
        cert)
            if [[ ${1:-} == enqueue ]]; then cert_enqueue "${2:-}"; return; fi;;
        api|bin|pbk|x25519|tls|run|uuid)
            [[ $command != bin ]] || { exec "$CORE" "$@"; }
            [[ $command != pbk ]] || command=x25519
            exec "$CORE" "$command" "$@";;
    esac
    if [[ $command == recover ]]; then context skip-recovery || return; else context || return; fi
    case $command in
        menu) menu;;
        share) menu_share;; service) menu_service;; logs) menu_log;; repair) menu_repair;;
        a|add) command_add "$@";;
        c|config|change)
            if (($#<=1)) && [[ -t 0 ]]; then menu_change "${1:-}"; else command_change "$@"; fi;;
        ob)
            if (($#==0)) && [[ -t 0 ]]; then menu_node_action ob
            else command_change "${1:-}" outbound "${@:2}"; fi;;
        d|del|rm|dd|ddel) command_delete "$@";;
        list) command_list;;
        i|info|url|qr|client|genc|debug)
            id=$(node_select "${1:-}") || return
            node=$(jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE")
            case $command in
                i|info) node_info "$node";; url) share_uri "$node";;
                qr) need qrencode; share_uri "$node" | qrencode -t ANSIUTF8;;
                client) node=$(client_json "$node" "${2:-current}") || return; jq -n --argjson o "$node" '{inbounds:[{listen:"127.0.0.1",port:1080,protocol:"socks",settings:{udp:true}}],outbounds:[$o]}' ;;
                genc) client_json "$node" "${2:-current}";; debug) json_redact <<< "$node";;
            esac;;
        new|full|port|id|passwd|pass|password|method|ssm|ss-method|ss_method|key|sni|host|path|seed|type|header|web|username|address|dda|ddp|dp|dynamicport|dynamic-port|publickey|privatekey|servername|servernames|kcpseed|kcp-seed|kcp_seed|header-type|header_type|door-addr|door_addr|door-port|door_port|proxy-site)
            command_change "${1:-}" "$command" "${@:2}";;
        cert)
            if (($#==0)) && [[ -t 0 ]]; then menu_cert; return; fi
            target=${1:-list}; (($#==0)) || shift
            case $target in setup) cert_setup "$@";; issue) cert_issue "${1:?需要域名}";; list) cert_list;; renew) cert_renew "${1:-}";; deploy) cert_deploy "${1:-}";; enqueue) cert_enqueue "${1:-}";; delete) command_remove_resource cert "${1:-}";; *) die '未知证书命令。';; esac;;
        domain) [[ ${1:-} == delete ]] && command_remove_resource domain "${2:-}";;
        recover) lock_state; recover_state "$([[ ${1:-} == --offline ]] && echo offline)"; unlock_state;;
        start|stop|r|restart)
            [[ $command != r ]] || command=restart
            target=${1:-xray-manager}
            [[ $target == xray-manager || $target == nginx ]] || { die '服务参数只能为 nginx。'; return; }
            note '这是整个服务的全局操作。'
            lock_state; recover_state
            unlock_state
            systemctl "$command" "$target.service";;
        s|status) systemctl status xray-manager.service --no-pager; [[ ! -e $NGINX_LOADER ]] || systemctl status nginx.service --no-pager;;
        t|test) write_begin; validate_generation "$ROOT/current"; unlock_state;;
        fix) command_change "${1:-}" full;;
        fix-all|fix-config.json|fix-nginx)
            note '修复为全局操作，以已提交源配置重建。'
            write_begin
            [[ $command != fix-all ]] || STATE=$(jq '.nodes|=map(.inbound_revision+=1)' <<< "$STATE")
            transaction; unlock_state;;
        fix-caddyfile) die '已改用 Nginx，请执行 xray fix-nginx。';;
        dns) if (($#==0)) && [[ -t 0 ]]; then menu_dns; else command_dns "$@"; fi;;
        log|logerr|errlog) command_log "$command" "${1:-}";;
        u|up|update|U|update.sh)
            if (($#==0)) && [[ -t 0 && $command != U && $command != update.sh ]]; then menu_update; return; fi
            target=${1:-core}; value=${2:-}
            [[ $command != U && $command != update.sh ]] || { target='sh'; value=${1:-}; }
            if [[ $target == sh && -z $value && -t 0 ]]; then value=$(prompt_step "已发布的脚本版本（例如 v$VERSION）") || return; fi
            case $target in
                core) update_core "${value:-v26.11.9}";;
                sh)
                    if [[ $command == U || $command == update.sh ]]; then update_manager "$value" "${@:2}"
                    else update_manager "$value" "${@:3}"; fi;;
                dat)
                    note '规则数据更新是全局操作。'; update_data;;
                nginx|certbot)
                    [[ $(jq -r --arg n "$target" '.[$n] // false' "$ROOT/ownership.json") == true ]] || { die '共享软件包不由本脚本自动升级，请使用系统包管理器。'; return; }
                    apt-get update && apt-get install --only-upgrade -y "$target";;
                caddy) die 'Caddy 已移除，使用 update nginx 或 cert。';;
                *) die '未知更新组件。';;
            esac;;
        un|uninstall) uninstall_manager;;
        reinstall) note '保留源配置，重新校验并恢复受管服务。'; main fix-all;;
        bbr)
            [[ -e /proc/sys/net/ipv4/tcp_congestion_control ]] || return 1
            modprobe tcp_bbr 2>/dev/null || true
            grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || { die '当前内核不支持 BBR。'; return; }
            printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-xray-manager-bbr.conf
            sysctl -p /etc/sysctl.d/90-xray-manager-bbr.conf;;
        get-port) free_port;; ip) detect_ip;; ss2022|ssss) ss_password "${1:-2022-blake3-aes-128-gcm}";;
        xapi) note 'API 透传不会保存到源配置，修复或重启后失效。'; api "${1:?缺少 API 命令}" "${@:2}";;
        gen|no-auto-tls)
            target=${1:-reality}; (($#==0)) || shift
            if [[ $command == no-auto-tls ]]; then command_add "$target" "$@" --manual-tls
            else
                build_node "$target" '{}' "$@" || return
                NODE=$(jq '.id="preview"|.name="preview"|.backend.port=20001' <<< "$NODE")
                STATE=$(jq --argjson n "$NODE" '.nodes=[$n]' <<< "$STATE")
                if [[ $(jq -r .security <<< "$NODE") =~ ^(nginx|tls)$ ]]; then
                    STATE=$(jq --arg d "$(jq -r .endpoint.domain <<< "$NODE")" --arg path "$LE_DIR/live/xray-$(jq -r .endpoint.domain <<< "$NODE")" '.settings.certificates[$d] //= {path:$path}' <<< "$STATE")
                fi
                jq --arg root "$ROOT" --arg socket "$SOCKET" -f "$MANAGER_HOME/jq/render.jq" <<< "$STATE"
            fi;;
        *) die '未知命令，请执行 xray help。';;
    esac
}
