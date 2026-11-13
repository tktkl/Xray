#!/usr/bin/env bash
render_config() {
    local generation=$1
    jq --arg root "$ROOT" --arg socket "$SOCKET" -f "$MANAGER_HOME/jq/render.jq" <<< "$STATE" > "$generation/config.json"
}
client_json() {
    # Reuse the same protocol rendering definitions for server and client.
    local defs
    defs=$(sed '/^\. as \$state/,$d' "$MANAGER_HOME/jq/render.jq")
    jq "$defs client_outbound" <<< "$1"
}
share_uri() {
    local node=$1 scheme id address port host security type name path query method password auth
    scheme=$(jq -r .kind <<< "$node"); id=$(jq -r .credentials.id <<< "$node")
    address=$(jq -r .endpoint.address <<< "$node"); port=$(jq -r .endpoint.port <<< "$node")
    host=$address; [[ $address == *:* ]] && address="[$address]"
    security=$(jq -r .security <<< "$node"); [[ $security == nginx ]] && security=tls
    type=$(jq -r .network <<< "$node"); name=$(uri_encode "$(jq -r .name <<< "$node")")
    path=$(jq -r .endpoint.path <<< "$node")
    case $scheme in
        shadowsocks)
            method=$(jq -r .credentials.method <<< "$node"); password=$(jq -r .credentials.password <<< "$node")
            auth=$(printf '%s' "$method:$password" | openssl base64 -A)
            printf 'ss://%s@%s:%s#%s\n' "$auth" "$address" "$port" "$name";;
        vmess)
            jq -cn --argjson n "$node" '{v:"2",ps:$n.name,add:$n.endpoint.address,port:($n.endpoint.port|tostring),id:$n.credentials.id,aid:"0",scy:"auto",net:$n.network,type:"none",host:$n.endpoint.domain,path:(if $n.network=="kcp" then (if ($n.kcp_compat//"native")=="legacy" then $n.credentials.seed else "" end) else $n.endpoint.path end),tls:(if $n.security=="nginx" or $n.security=="tls" then "tls" else "" end),sni:$n.endpoint.domain}' | tr -d '\n' | openssl base64 -A | { IFS= read -r auth || :; printf 'vmess://%s\n' "$auth"; };;
        vless|trojan)
            query="security=$security&type=$type"
            [[ $scheme == vless ]] && query+="&encryption=none"
            if [[ $security == reality ]]; then
                query+="&flow=xtls-rprx-vision&sni=$(uri_encode "$(jq -r .sni <<< "$node")")&pbk=$(uri_encode "$(jq -r .credentials.public_key <<< "$node")")&sid=$(jq -r .credentials.short_id <<< "$node")&fp=chrome"
            elif [[ $security == tls ]]; then query+="&sni=$(uri_encode "$(jq -r .endpoint.domain <<< "$node")")"; fi
            case $type in
                ws|xhttp) query+="&host=$(uri_encode "$(jq -r .endpoint.domain <<< "$node")")&path=$(uri_encode "$path")";;
                grpc) query+="&serviceName=$(uri_encode "${path#/}")";;
            esac
            [[ $scheme == trojan ]] && id=$(jq -r .credentials.password <<< "$node")
            printf '%s://%s@%s:%s?%s#%s\n' "$scheme" "$(uri_encode "$id")" "$address" "$port" "$query" "$name";;
        hysteria)
            printf 'hysteria2://%s@%s:%s?sni=%s#%s\n' "$(uri_encode "$(jq -r .credentials.password <<< "$node")")" "$address" "$port" "$(uri_encode "$(jq -r .endpoint.domain <<< "$node")")" "$name";;
        socks)
            printf 'socks5://%s:%s@%s:%s#%s\n' "$(uri_encode "$(jq -r .credentials.username <<< "$node")")" "$(uri_encode "$(jq -r .credentials.password <<< "$node")")" "$address" "$port" "$name";;
        *) die '此协议不支持分享链接。';;
    esac
}
