#!/usr/bin/env bash
# URI values are data, never executable shell text.
uri_decode() {
    local input=$1 output='' char hex i=0
    while ((i<${#input})); do
        char=${input:i:1}
        if [[ $char == % ]]; then
            hex=${input:i+1:2}
            [[ $hex =~ ^[a-fA-F0-9]{2}$ && $hex != 00 && $hex != 0[aAdD] ]] || { die '非法 URI 编码。'; return; }
            printf -v char '%b' "\\x$hex"
            ((i+=2))
        fi
        output+=$char; ((i+=1))
    done
    nonempty "$output" || return
    printf '%s' "$output"
}
uri_encode() { jq -rn --arg s "$1" '$s|@uri'; }
base64_decode() {
    local s=${1//-/+}; s=${s//_/\/}
    [[ $s =~ ^[a-zA-Z0-9+/]*={0,2}$ ]] || { die '非法 Base64。'; return; }
    case $((${#s}%4)) in 2) s+='==';; 3) s+='=';; 1) die '非法 Base64 长度。'; return 1;; esac
    printf '%s' "$s" | openssl base64 -d -A
}
split_authority() {
    local authority=$1
    if [[ $authority =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[2]}
    elif [[ $authority =~ ^([^:]+):([0-9]+)$ ]]; then URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[2]}
    else die '节点地址必须包含端口，IPv6 请使用方括号。'; return 1; fi
    valid_address "$URI_HOST" && valid_port "$URI_PORT" || { die '无效节点地址或端口。'; return; }
    URI_PORT=$((10#$URI_PORT))
}
parse_query() {
    QUERY='{}'
    local part key value
    local -a pairs=()
    IFS='&' read -r -a pairs <<< "$1"
    for part in "${pairs[@]}"; do
        [[ -n $part ]] || continue
        [[ $part == *=* ]] || { die '参数缺少值。'; return; }
        key=$(uri_decode "${part%%=*}") || return
        value=${part#*=}; [[ -z $value ]] || value=$(uri_decode "$value") || return
        [[ $(jq --arg k "$key" 'has($k)' <<< "$QUERY") == false ]] || { die '重复的链接参数。'; return; }
        QUERY=$(jq --arg k "$key" --arg v "$value" '.[$k]=$v' <<< "$QUERY")
    done
}
outbound_from_uri() {
    local link=$1 scheme body userinfo authority query='' method password user network security sni path stream settings value scy=auto
    nonempty "$link" || return
    [[ $link == *://* ]] || { die '请输入完整节点分享链接。'; return; }
    scheme=${link%%://*}; body=${link#*://}; body=${body%%#*}
    if [[ $scheme == vmess ]]; then
        value=$(base64_decode "$body") || return
        jq -e 'type=="object" and (.add|type=="string") and (.id|type=="string") and (.port|tostring|test("^[0-9]+$"))' <<< "$value" >/dev/null || { die '非法 VMess 链接。'; return; }
        jq -e 'keys - ["v","ps","add","port","id","aid","scy","net","type","host","path","tls","sni","alpn","fp"] == []' <<< "$value" >/dev/null || { die 'VMess 链接包含未支持字段。'; return; }
        [[ $(jq -r '.aid // "0"|tostring' <<< "$value") == 0 && $(jq -r '.type // "none"' <<< "$value") == none ]] || { die '仅支持 alterId=0、无旧式 header 的 VMess。'; return; }
        URI_HOST=$(jq -r .add <<< "$value"); URI_PORT=$(jq -r .port <<< "$value")
        userinfo=$(jq -r .id <<< "$value")
        scy=$(jq -r '.scy // "auto"' <<< "$value")
        QUERY=$(jq '{type:(.net//"tcp"),security:(if .tls=="tls" then "tls" else "none" end),sni:(.sni//.host//.add),host:(.host//""),path:(.path//"/"),fp:(.fp//"chrome"),alpn:(.alpn//"")}' <<< "$value")
    else
        if [[ $body == *\?* ]]; then query=${body#*\?}; body=${body%%\?*}; fi
        parse_query "$query" || return
        if [[ $scheme == ss && $body != *@* ]]; then body=$(base64_decode "$body") || return; fi
        [[ $body == *@* ]] || { die '链接缺少认证信息。'; return; }
        userinfo=${body%@*}; authority=${body##*@}; authority=${authority%/}
        split_authority "$authority" || return
        if [[ $scheme == ss && $userinfo != *:* && $userinfo != *%* ]]; then userinfo=$(base64_decode "$userinfo") || return
        else userinfo=$(uri_decode "$userinfo") || return; fi
    fi
    valid_address "$URI_HOST" && valid_port "$URI_PORT" || { die '无效节点端点。'; return; }
    URI_PORT=$((10#$URI_PORT))
    jq -e 'keys - ["encryption","security","type","sni","pbk","sid","fp","flow","path","host","serviceName","mode","alpn","allowInsecure"] == []' <<< "$QUERY" >/dev/null || { die '节点链接包含未支持字段（包括 SS plugin），未导入。'; return; }
    if [[ $scheme == ss ]]; then
        [[ $(jq length <<< "$QUERY") == 0 ]] || { die 'SS 出口不支持附加查询参数。'; return; }
    fi
    if [[ $scheme == vless ]]; then
        [[ $(jq -r '.encryption // "none"' <<< "$QUERY") == none ]] || { die '仅支持 encryption=none 的 VLESS 出口。'; return; }
    fi
    [[ $(jq -r '.allowInsecure // "0"' <<< "$QUERY") =~ ^(0|false)$ ]] || { die '不接受跳过证书校验的出口。'; return; }
    network=$(jq -r '.type // "tcp"' <<< "$QUERY")
    security=$(jq -r --arg scheme "$scheme" '.security // (if $scheme=="trojan" then "tls" else "none" end)' <<< "$QUERY")
    sni=$(jq -r --arg h "$URI_HOST" '.sni // $h' <<< "$QUERY"); path=$(jq -r '.path // "/"' <<< "$QUERY")
    case $network in tcp|raw|ws|grpc|xhttp) ;; *) die '不支持的出口传输类型。'; return 1;; esac
    if [[ $network != xhttp ]] && jq -e 'has("mode")' <<< "$QUERY" >/dev/null; then die 'mode 仅用于 XHTTP。'; return 1; fi
    if [[ $network != grpc ]] && jq -e 'has("serviceName")' <<< "$QUERY" >/dev/null; then die 'serviceName 仅用于 gRPC。'; return 1; fi
    if [[ $security == none ]] && jq -e 'has("sni") or has("pbk") or has("sid") or has("fp") or has("alpn")' <<< "$QUERY" >/dev/null; then
        # VMess JSON exports conventionally carry these empty/default fields.
        [[ $scheme == vmess ]] || { die '无安全层的出口不能指定 TLS/REALITY 参数。'; return; }
    fi
    stream=$(jq -n --arg net "$network" '{network:$net}')
    case $network in
        ws) stream=$(jq --arg p "$path" --arg host "$(jq -r '.host // ""' <<< "$QUERY")" '.+{wsSettings:{path:$p,host:$host}}' <<< "$stream");;
        grpc) stream=$(jq --arg name "$(jq -r '.serviceName // .path // ""|ltrimstr("/")' <<< "$QUERY")" '.+{grpcSettings:{serviceName:$name}}' <<< "$stream");;
        xhttp) stream=$(jq --arg p "$path" --arg host "$(jq -r '.host // ""' <<< "$QUERY")" --arg mode "$(jq -r '.mode // "auto"' <<< "$QUERY")" '.+{xhttpSettings:{path:$p,host:$host,mode:$mode}}' <<< "$stream");;
    esac
    case $security in
        none|'') stream=$(jq '.security="none"' <<< "$stream");;
        tls) stream=$(jq --arg s "$sni" --arg fp "$(jq -r '.fp // "chrome"' <<< "$QUERY")" --arg alpn "$(jq -r '.alpn // ""' <<< "$QUERY")" '.+{security:"tls",tlsSettings:({serverName:$s,allowInsecure:false,useSystemCA:true,fingerprint:$fp}+(if $alpn=="" then {} else {alpn:($alpn|split(","))} end))}' <<< "$stream");;
        reality)
            [[ $scheme == vless ]] || { die 'REALITY 出口需要 VLESS。'; return; }
            [[ -n $(jq -r '.pbk // ""' <<< "$QUERY") ]] || { die 'REALITY 出口缺少 pbk。'; return; }
            stream=$(jq --arg s "$sni" --argjson q "$QUERY" '.+{security:"reality",realitySettings:{serverName:$s,password:$q.pbk,shortId:($q.sid//""),fingerprint:($q.fp//"chrome")}}' <<< "$stream");;
        *) die '不支持的出口安全类型。'; return 1;;
    esac
    case $scheme in
        ss)
            [[ $userinfo == *:* ]] || { die 'SS 链接缺少 method/password。'; return; }
            method=${userinfo%%:*}; password=${userinfo#*:}
            validate_ss "$method" "$password" || return
            settings=$(jq -n --arg a "$URI_HOST" --argjson p "$URI_PORT" --arg m "$method" --arg pass "$password" '{servers:[{address:$a,port:$p,method:$m,password:$pass}]}')
            scheme=shadowsocks; stream='{}';;
        vless|vmess)
            valid_uuid "$userinfo" || { die '无效 UUID。'; return; }
            settings=$(jq -n --arg a "$URI_HOST" --argjson p "$URI_PORT" --arg id "$userinfo" --arg kind "$scheme" --arg flow "$(jq -r '.flow // ""' <<< "$QUERY")" --arg scy "$scy" '{vnext:[{address:$a,port:$p,users:[({id:$id}+(if $kind=="vless" then {encryption:"none",flow:$flow} else {security:$scy} end))]}]}');;
        trojan)
            [[ $security != none ]] || { die 'Trojan 出口必须使用 TLS。'; return; }
            settings=$(jq -n --arg a "$URI_HOST" --argjson p "$URI_PORT" --arg pass "$userinfo" '{servers:[{address:$a,port:$p,password:$pass}]}');;
        socks|socks5|http)
            [[ $userinfo == *:* ]] || { die '代理链接必须包含用户名和密码。'; return; }
            user=${userinfo%%:*}; password=${userinfo#*:}; [[ $scheme == socks5 ]] && scheme=socks
            settings=$(jq -n --arg a "$URI_HOST" --argjson p "$URI_PORT" --arg u "$user" --arg pass "$password" '{servers:[{address:$a,port:$p,users:[{user:$u,pass:$pass}]}]}');;
        *) die '支持 ss/vless/vmess/trojan/socks5/http 链接。'; return 1;;
    esac
    jq -n --arg protocol "$scheme" --argjson s "$settings" --argjson t "$stream" '{protocol:$protocol,settings:$s}+(if $t=={} then {} else {streamSettings:$t} end)'
}
