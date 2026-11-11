#!/usr/bin/env bash
help_text() {
    cat <<'EOF'
Xray 独立管理脚本 0.1.0
用法：xray [命令] [参数]；不带参数打开菜单。

节点：
  a, add [协议] [参数...|auto] [--name 名称] [--address 对外地址]
  c, change [节点] [修改项] [值...]
  d, del, rm [节点]                dd, ddel 节点...
  i, info [节点]                  list
  url, qr [节点]                  client, genc [节点]
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
    if [[ -z $protocol ]]; then protocol=$(prompt '协议 reality/ss/tcp/kcp/vws/vgrpc/xhttp/tws/tgrpc/hy2/socks/door' reality)
    else shift; fi
    build_node "$protocol" '{}' "$@" || return
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
    jq -r '.nodes[]|[.id,.name,.protocol,(.endpoint.address+":"+(.endpoint.port|tostring)),.outbound.protocol]|@tsv' <<< "$STATE"
}
command_change() {
    local selector=${1:-} option=${2:-} id old value method public private domain args protocol
    (($#<2)) || shift 2
    id=$(node_select "$selector") || return
    old=$(jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE")
    NODE=$old
    if [[ -z $option ]]; then option=$(prompt '修改项 port/id/passwd/new/outbound/host/path/sni/web' port); fi
    value=$(auto_value "${1:-}")
    case $option in
        new)
            protocol=${1:-$(prompt '新的协议' reality)}
            (($#==0)) || shift
            if (($#==0)); then
                case $(canonical_protocol "$protocol") in
                    *-TLS) set -- "$(jq -r .endpoint.domain <<< "$old")";;
                    *) set -- "$(jq -r .endpoint.port <<< "$old")";;
                esac
                set -- "$@" --address "$(jq -r .endpoint.address <<< "$old")"
            fi
            build_node "$protocol" "$old" "$@" || return
            NODE=$(jq --argjson old "$old" '.id=$old.id|.name=(if .name=="" then $old.name else .name end)|.outbound=$old.outbound|.outbound_revision=$old.outbound_revision|.inbound_revision=($old.inbound_revision+1)|.backend=$old.backend' <<< "$NODE");;
        full)
            if (($#)); then
                protocol=$(jq -r .protocol <<< "$old")
                build_node "$protocol" "$old" "$@" || return
                NODE=$(jq --argjson old "$old" '.id=$old.id|.name=$old.name|.outbound=$old.outbound|.outbound_revision=$old.outbound_revision|.inbound_revision=($old.inbound_revision+1)|.backend=$old.backend' <<< "$NODE")
            else NODE=$(jq '.inbound_revision+=1' <<< "$old"); fi;;
        ob|outbound)
            value=${value:-$(prompt '出口：direct 或粘贴 ss/vless/vmess/trojan/socks5/http 链接' direct)}
            if [[ $value == direct ]]; then value='{"protocol":"freedom","settings":{}}'
            else value=$(outbound_from_uri "$value") || return; fi
            NODE=$(jq --argjson o "$value" '.outbound=$o|.outbound_revision+=1' <<< "$NODE");;
        port)
            value=${value:-$(free_port)}; valid_port "$value" || { die '无效端口。'; return; }
            value=$((10#$value))
            NODE=$(jq --argjson p "$value" '.endpoint.port=$p|.inbound_revision+=(if .security=="nginx" then 0 else 1 end)' <<< "$NODE");;
        id|uuid)
            [[ $(jq -r .kind <<< "$NODE") =~ ^(vless|vmess)$ ]] || { die '当前协议不使用 UUID。'; return; }
            value=${value:-$(uuid)}; valid_uuid "$value" || { die '无效 UUID。'; return; }
            NODE=$(jq --arg v "$value" '.credentials.id=$v|.inbound_revision+=1' <<< "$NODE");;
        passwd|pass|password)
            [[ $(jq -r .kind <<< "$NODE") =~ ^(shadowsocks|trojan|hysteria|socks)$ ]] || { die '当前协议不使用密码。'; return; }
            method=$(jq -r .credentials.method <<< "$NODE")
            if [[ $(jq -r .kind <<< "$NODE") == shadowsocks ]]; then value=${value:-$(ss_password "$method")}; validate_ss "$method" "$value" || return
            else value=${value:-$(random_hex 24)}; fi
            nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.password=$v|.inbound_revision+=1' <<< "$NODE");;
        method|ssm|ss-method|ss_method)
            [[ $(jq -r .kind <<< "$NODE") == shadowsocks ]] || { die '只有 SS 支持 method。'; return; }
            value=${value:-2022-blake3-aes-128-gcm}
            args=$(ss_password "$value"); validate_ss "$value" "$args" || return
            NODE=$(jq --arg m "$value" --arg p "$args" '.credentials.method=$m|.credentials.password=$p|.inbound_revision+=1' <<< "$NODE");;
        key|publickey|privatekey)
            [[ $(jq -r .security <<< "$NODE") == reality ]] || { die '只有 REALITY 支持此密钥修改。'; return; }
            if [[ -n $value ]]; then args=$("$CORE" x25519 -i "$value") || return
            else args=$("$CORE" x25519) || return; fi
            private=$(awk -F ': ' '/^Private[Kk]ey:/{print $2}' <<< "$args")
            public=$(awk -F ': ' '/^(Public[Kk]ey|Password)/{print $2}' <<< "$args")
            [[ -n $private && -n $public ]] || return 1
            [[ -z ${2:-} || $2 == "$public" ]] || { die '给定公钥与私钥不匹配。'; return; }
            NODE=$(jq --arg private "$private" --arg public "$public" '.credentials.private_key=$private|.credentials.public_key=$public|.inbound_revision+=1' <<< "$NODE");;
        sni|servername|servernames)
            [[ $(jq -r .security <<< "$NODE") == reality ]] || { die '此命令只修改 REALITY SNI。'; return; }
            value=${value:-$(choose_reality)}; probe_reality "$value" || { die 'SNI 检测失败。'; return; }
            NODE=$(jq --arg v "$value" '.sni=$v|.inbound_revision+=1' <<< "$NODE");;
        host)
            [[ -n $(jq -r .endpoint.domain <<< "$NODE") ]] || { die '此节点不使用证书域名。'; return; }
            value=${value:-$(prompt '新域名')}; value=${value,,}
            valid_domain "$value" || { die '无效域名。'; return; }
            NODE=$(jq --arg v "$value" '.endpoint.domain=$v|.endpoint.address=$v|.inbound_revision+=1' <<< "$NODE");;
        address)
            value=${value:-$(prompt '对外地址')}; valid_address "$value" || return
            NODE=$(jq --arg v "$value" '.endpoint.address=$v' <<< "$NODE");;
        path)
            [[ $(jq -r .network <<< "$NODE") =~ ^(ws|grpc|xhttp)$ ]] || { die '此协议没有反代路径。'; return; }
            value=${value:-/$(random_hex 12)}; valid_path "$value" && [[ $value != / ]] || { die '无效路径。'; return; }
            NODE=$(jq --arg v "$value" '.endpoint.path=$v|.inbound_revision+=1' <<< "$NODE");;
        seed|kcpseed|kcp-seed|kcp_seed)
            [[ $(jq -r .network <<< "$NODE") == kcp ]] || { die '此协议不支持 seed。'; return; }
            value=${value:-$(random_hex 12)}; nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.seed=$v|.inbound_revision+=1' <<< "$NODE");;
        type|header|header-type|header_type)
            [[ $(jq -r .network <<< "$NODE") =~ ^(tcp|kcp)$ ]] || { die '此协议不支持 header。'; return; }
            [[ ${value:-none} == none ]] || { die '此核心不支持所请求的旧式 header。'; return; }
            NODE=$(jq '.credentials.header="none"|.inbound_revision+=1' <<< "$NODE");;
        username)
            [[ $(jq -r .kind <<< "$NODE") == socks ]] || return 1
            value=${value:-$(prompt '用户名')}; nonempty "$value" || return
            NODE=$(jq --arg v "$value" '.credentials.username=$v|.inbound_revision+=1' <<< "$NODE");;
        dda|door-addr|door_addr)
            [[ $(jq -r .kind <<< "$NODE") == dokodemo-door ]] || return 1
            valid_address "$value" || return
            NODE=$(jq --arg v "$value" '.remote.address=$v|.inbound_revision+=1' <<< "$NODE");;
        ddp|door-port|door_port)
            [[ $(jq -r .kind <<< "$NODE") == dokodemo-door ]] || return 1
            valid_port "$value" || { die '无效目标端口。'; return; }
            NODE=$(jq --argjson v "$value" '.remote.port=$v|.inbound_revision+=1' <<< "$NODE");;
        web|proxy-site)
            domain=$(jq -r .endpoint.domain <<< "$NODE")
            [[ $(jq -r .security <<< "$NODE") == nginx ]] || { die '此节点没有 Nginx 站点。'; return; }
            value=${value:-$(prompt '伪装网站域名或 static' static)}
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
    if (($#==0)); then ids+=("$(node_select '')")
    else for selector in "$@"; do id=$(node_select "$selector") || return; ids+=("$id"); done; fi
    write_begin || return
    for id in "${ids[@]}"; do STATE=$(jq --arg id "$id" '.nodes|=map(select(.id!=$id))' <<< "$STATE"); done
    transaction || { unlock_state; return 1; }
    unlock_state
}
command_dns() {
    local value=${1:-} dns
    [[ -n $value ]] || value=$(prompt 'DNS：none/11/88/google/cloudflare/family/set' none)
    case $value in
        none) dns='["localhost"]';;
        11|1111) dns='["1.1.1.1"]';;
        88|8888) dns='["8.8.8.8"]';;
        gg|google) dns='["https+local://dns.google/dns-query"]';;
        cf|cloudflare) dns='["https+local://cloudflare-dns.com/dns-query"]';;
        nosex|family) dns='["https+local://family.cloudflare-dns.com/dns-query"]';;
        set) value=${2:-$(prompt 'DNS 地址')}; nonempty "$value" || return; dns=$(jq -n --arg d "$value" '[$d]');;
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
    if [[ -z $value ]]; then tail -F "$ROOT/logs/$([[ $target == log ]] && echo access || echo error).log"; return; fi
    if [[ $value == del ]]; then
        : > "$ROOT/logs/access.log"; : > "$ROOT/logs/error.log"; return
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
menu() {
    local choice
    printf '1) 添加节点\n2) 修改节点\n3) 查看节点\n4) 删除节点\n5) 运行状态\n6) 帮助\n'
    choice=$(prompt '选择' 1)
    case $choice in 1) command_add;; 2) command_change;; 3) command_list;; 4) command_delete;; 5) systemctl status xray-manager.service --no-pager;; *) help_text;; esac
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
        a|add) command_add "$@";;
        c|config|change) command_change "$@";;
        ob) command_change "${1:-}" outbound "${@:2}";;
        d|del|rm|dd|ddel) command_delete "$@";;
        list) command_list;;
        i|info|url|qr|client|genc|debug)
            id=$(node_select "${1:-}") || return
            node=$(jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$STATE")
            case $command in
                i|info) node_info "$node";; url) share_uri "$node";;
                qr) need qrencode; share_uri "$node" | qrencode -t ANSIUTF8;;
                client) node=$(client_json "$node") || return; jq -n --argjson o "$node" '{inbounds:[{listen:"127.0.0.1",port:1080,protocol:"socks",settings:{udp:true}}],outbounds:[$o]}' ;;
                genc) client_json "$node";; debug) json_redact <<< "$node";;
            esac;;
        new|full|port|id|passwd|pass|password|method|ssm|ss-method|ss_method|key|sni|host|path|seed|type|header|web|username|address|dda|ddp|dp|dynamicport|dynamic-port|publickey|privatekey|servername|servernames|kcpseed|kcp-seed|kcp_seed|header-type|header_type|door-addr|door_addr|door-port|door_port|proxy-site)
            command_change "${1:-}" "$command" "${@:2}";;
        cert)
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
        dns) command_dns "$@";;
        log|logerr|errlog) command_log "$command" "${1:-}";;
        u|up|update|U|update.sh)
            target=${1:-core}; value=${2:-}
            [[ $command != U && $command != update.sh ]] || { target='sh'; value=${1:-}; }
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
