#!/usr/bin/env bash
valid_uuid() { [[ $1 =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]; }
validate_ss() {
    local method=$1 password=$2 bytes
    nonempty "$password" || return
    case $method in
        aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) ;;
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            bytes=$(base64_decode "$password" | wc -c) || return
            if [[ $method == 2022-blake3-aes-128-gcm ]]; then [[ $bytes == 16 ]]
            else [[ $bytes == 32 ]]; fi || { die 'SS2022 密钥长度与加密方式不匹配。'; return; };;
        *) die '不支持的 Shadowsocks 加密方式。'; return 1;;
    esac
}
ss_password() {
    if [[ ${1:-} == 2022-blake3-aes-128-gcm ]]; then openssl rand -base64 16
    else openssl rand -base64 32; fi
}
free_port() {
    local port tries
    for ((tries=0;tries<100;tries++)); do
        port=$(shuf -i 20000-60000 -n 1)
        if ! ss -H -lntu "sport = :$port" | read -r _; then
            if [[ -z ${STATE:-} ]] || ! jq -e --argjson p "$port" '.nodes[]|select(.endpoint.port==$p or .backend.port==$p)' <<< "$STATE" >/dev/null; then
                printf '%s\n' "$port"; return
            fi
        fi
    done
    die '未找到可用端口。'
}
probe_reality() {
    local sni=$1 result
    valid_domain "$sni" || { die 'SNI 必须是有效域名。'; return; }
    if [[ ${XRAY_TESTING:-0} == 1 && $ROOT == /tmp/* && ${XRAY_TEST_REALITY_OK:-0} == 1 ]]; then return; fi
    result=$(timeout 12 openssl s_client -connect "$sni:443" -servername "$sni" -verify_hostname "$sni" \
        -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1) || return 1
    [[ $result == *'ALPN protocol: h2'* && $result == *'TLSv1.3'* && $result == *'Verify return code: 0 (ok)'* ]]
}
choose_reality() {
    local sni
    local -a passed=()
    for sni in apps.mzstatic.com xp.apple.com; do
        if probe_reality "$sni"; then passed+=("$sni"); else note "REALITY 候选检测失败：$sni"; fi
    done
    ((${#passed[@]})) || { die '所有默认 SNI 均未通过 TLS 1.3/H2/证书检测，请显式指定可用 SNI。'; return; }
    printf '%s\n' "${passed[$(shuf -i "0-$((${#passed[@]}-1))" -n 1)]}"
}
canonical_protocol() {
    case ${1,,} in
        r|reality|vless-reality) echo VLESS-REALITY;;
        tcp|vmess-tcp) echo VMess-TCP;;
        kcp|mkcp|vmess-mkcp) echo VMess-mKCP;;
        ws|vmess-ws-tls) echo VMess-WS-TLS;;
        grpc|vmess-grpc-tls) echo VMess-gRPC-TLS;;
        vws|vless-ws-tls) echo VLESS-WS-TLS;;
        vgrpc|vless-grpc-tls) echo VLESS-gRPC-TLS;;
        xhttp|vless-xhttp-tls) echo VLESS-XHTTP-TLS;;
        tws|trojan-ws-tls) echo Trojan-WS-TLS;;
        tgrpc|trojan-grpc-tls) echo Trojan-gRPC-TLS;;
        ss|shadowsocks) echo Shadowsocks;;
        hy|hy2|hysteria2) echo Hysteria2;;
        socks) echo Socks;;
        door|dokodemo-door) echo Dokodemo-Door;;
        tcpd|kcpd|*dynamic*) die '上游已移除动态端口功能，本脚本不支持。'; return 1;;
        *) die '未知协议，请查看 xray help。'; return 1;;
    esac
}
parse_build_options() {
    POSITIONAL=(); OPT_DOMAIN=; OPT_ADDRESS=; OPT_NAME=; OPT_LISTEN=0.0.0.0; OPT_MANUAL=false
    while (($#)); do
        case $1 in
            --domain|--address|--name|--listen)
                (($#>=2)) || { die "缺少 $1 的值。"; return; }
                case $1 in --domain) OPT_DOMAIN=${2,,};; --address) OPT_ADDRESS=$2;; --name) OPT_NAME=$2;; --listen) OPT_LISTEN=$2;; esac
                shift 2;;
            --manual-tls) OPT_MANUAL=true; shift;;
            --*) die "未知参数：$1"; return 1;;
            *) POSITIONAL+=("$1"); shift;;
        esac
    done
}
build_node() {
    local protocol=$1 old=${2:-'{}'}
    shift 2
    parse_build_options "$@" || return
    protocol=$(canonical_protocol "$protocol") || return
    local kind network=tcp security=none domain=$OPT_DOMAIN address=$OPT_ADDRESS port id pass method sni='' private='' public='' sid='' path=/ username='' seed='' header=none remote_address='' remote_port=0 keys
    local -a args=("${POSITIONAL[@]}")
    case $protocol in
        VLESS*) kind=vless;; VMess*) kind=vmess;; Trojan*) kind=trojan;;
        Shadowsocks) kind=shadowsocks;; Hysteria2) kind=hysteria;; Socks) kind=socks;; Dokodemo-Door) kind=dokodemo-door;;
    esac
    case $protocol in *-WS-TLS) network=ws;; *-gRPC-TLS) network=grpc;; *-XHTTP-TLS) network=xhttp;; *mKCP) network=kcp;; Hysteria2) network=hysteria;; esac
    id=$(auto_value "${args[1]:-}")
    if [[ $protocol == *-TLS ]]; then
        security=nginx; domain=${domain:-$(auto_value "${args[0]:-}")}
        domain=${domain:-$(prompt '请输入证书域名')}; domain=${domain,,}
        valid_domain "$domain" || { die '无效证书域名。'; return; }
        port=443; path=$(auto_value "${args[2]:-}"); path=${path:-/$(random_hex 12)}
        valid_path "$path" && [[ $path != / ]] || { die '需要非根路径，只允许安全路径字符。'; return; }
    else port=$(auto_value "${args[0]:-}"); port=${port:-$(free_port)}; fi
    valid_port "$port" || { die '无效端口。'; return; }
    port=$((10#$port))
    if [[ $kind == vless || $kind == vmess ]]; then
        id=${id:-$(jq -r '.credentials.id // empty' <<< "$old")}; id=${id:-$(uuid)}
        valid_uuid "$id" || { die '无效 UUID。'; return; }
    else id=$(uuid); fi
    pass=$(random_hex 24); method=2022-blake3-aes-128-gcm
    case $protocol in
        VLESS-REALITY)
            security=reality; sni=$(auto_value "${args[2]:-}")
            if [[ -n $sni ]]; then probe_reality "$sni" || { die '指定的 SNI 未通过检测。'; return; }
            else sni=$(choose_reality) || return; fi
            keys=$("$CORE" x25519)
            private=$(awk -F ': ' '/^Private[Kk]ey:/{print $2}' <<< "$keys")
            public=$(awk -F ': ' '/^(Public[Kk]ey|Password)/{print $2}' <<< "$keys")
            [[ -n $private && -n $public ]] || { die '无法识别核心的 X25519 输出。'; return; }
            sid=$(random_hex 8);;
        Shadowsocks)
            method=$(auto_value "${args[2]:-}"); method=${method:-2022-blake3-aes-128-gcm}
            pass=$(auto_value "${args[1]:-}"); pass=${pass:-$(ss_password "$method")}
            validate_ss "$method" "$pass" || return;;
        Hysteria2)
            security=tls; domain=${domain:-$(prompt '请输入证书域名')}; domain=${domain,,}
            valid_domain "$domain" || { die 'Hysteria2 需要有效域名。'; return; }
            pass=$(auto_value "${args[1]:-}"); pass=${pass:-$(random_hex 24)};;
        Socks)
            username=$(auto_value "${args[1]:-}"); username=${username:-user-$(random_hex 4)}
            pass=$(auto_value "${args[2]:-}"); pass=${pass:-$(random_hex 24)};;
        Dokodemo-Door)
            remote_address=${args[1]:-}; remote_port=${args[2]:-0}
            valid_address "$remote_address" && valid_port "$remote_port" || { die '端口转发需要目标地址和端口。'; return; };;
        VMess-TCP|VMess-mKCP)
            header=$(auto_value "${args[2]:-}"); header=${header:-none}
            [[ $header == none ]] || { die '当前核心只支持本脚本提供的 none 伪装；不生成已移除的旧式 header。'; return; }
            seed=$(random_hex 12);;
        Trojan*) pass=$(auto_value "${args[1]:-}"); pass=${pass:-$(random_hex 24)};;
    esac
    nonempty "$pass" || return
    address=${address:-${domain:-$(detect_ip)}}
    valid_address "$address" && valid_address "$OPT_LISTEN" || return
    [[ -z $OPT_NAME ]] || nonempty "$OPT_NAME" || return
    NODE=$(jq -n --arg protocol "$protocol" --arg kind "$kind" --arg net "$network" --arg sec "$security" \
      --arg addr "$address" --argjson port "$port" --arg domain "$domain" --arg path "$path" --arg name "$OPT_NAME" --arg listen "$OPT_LISTEN" \
      --arg id "$id" --arg pass "$pass" --arg method "$method" --arg private "$private" --arg public "$public" --arg sid "$sid" --arg sni "$sni" \
      --arg user "$username" --arg seed "$seed" --arg header "$header" --arg remote "$remote_address" --argjson rp "$remote_port" --argjson manual "$OPT_MANUAL" \
      '{id:"",name:$name,protocol:$protocol,kind:$kind,network:$net,security:$sec,manual_tls:$manual,listen:$listen,inbound_revision:1,outbound_revision:1,
      endpoint:{address:$addr,port:$port,domain:$domain,path:$path},backend:{port:0},credentials:{id:$id,password:$pass,method:$method,private_key:$private,public_key:$public,short_id:$sid,username:$user,seed:$seed,header:$header},
      sni:$sni,remote:{address:$remote,port:$rp},outbound:{protocol:"freedom",settings:{}}}')
    if [[ $OPT_MANUAL == true ]]; then
        [[ $security == nginx ]] || { die 'no-auto-tls 仅适用于反代 TLS 协议。'; return; }
        NODE=$(jq '.security="none"' <<< "$NODE")
    fi
}
detect_ip() {
    local ip
    ip=$(ip -j route get 1.1.1.1 2>/dev/null | jq -r '.[0].prefsrc // empty')
    [[ -n $ip ]] || { die '无法确定对外地址，请使用 --address。'; return; }
    note "对外地址默认使用 $ip；有 NAT 时请通过 --address 指定公网地址。"
    printf '%s' "$ip"
}
