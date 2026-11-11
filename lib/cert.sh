#!/usr/bin/env bash
LE_DIR=${XRAY_LE_DIR:-/etc/letsencrypt}
cert_setup() {
    require_root
    local credentials='' email='' token
    while (($#)); do
        (($#>=2)) || { die 'cert setup 参数缺少值。'; return; }
        case $1 in --credentials) credentials=$2;; --email) email=$2;; *) die '使用 cert setup [--credentials FILE] [--email EMAIL]'; return 1;; esac
        shift 2
    done
    email=${email:-$(prompt 'ACME 联系邮箱')}
    [[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { die '无效邮箱。'; return; }
    mkdir -p "$ROOT"
    if [[ -n $credentials ]]; then
        credentials=$(readlink -f "$credentials")
        [[ -f $credentials && ! -L $credentials && $(stat -c '%u:%a' "$credentials") == 0:600 ]] || { die '凭据必须为 root 所有、0600 的普通文件。'; return; }
        grep -Eq '^dns_cloudflare_api_token[[:space:]]*=[[:space:]]*[^[:space:]]+' "$credentials" || { die '凭据缺少 dns_cloudflare_api_token。'; return; }
    else
        [[ -t 0 ]] || { die '非交互模式请通过 --credentials 引用 0600 凭据文件；不要把 Token 放在命令行。'; return; }
        read -r -s -p 'Cloudflare API Token: ' token; printf '\n' >&2
        [[ $token =~ ^[a-zA-Z0-9_-]{20,}$ ]] || { die '无效 Token 格式。'; return; }
        credentials="$ROOT/cloudflare.ini"
        printf 'dns_cloudflare_api_token = %s\n' "$token" | atomic_file "$credentials"
        unset token
    fi
    jq -n --arg credentials "$credentials" --arg email "$email" '{credentials:$credentials,email:$email,propagation_seconds:60}' | atomic_file "$ROOT/acme.json"
    note 'Cloudflare 凭据已配置；只管理验证 TXT，不修改 A/AAAA 或橙云。'
}
cert_issue() {
    local domain=${1,,} credentials email
    valid_domain "$domain" || { die '证书需要有效的单个域名，不支持通配符。'; return; }
    [[ -e $ROOT/acme.json ]] || cert_setup || return
    ensure_component certbot || return
    credentials=$(jq -r .credentials "$ROOT/acme.json"); email=$(jq -r .email "$ROOT/acme.json")
    [[ $(stat -c '%u:%a' "$credentials") == 0:600 ]] || { die 'Cloudflare 凭据权限必须是 root:0600。'; return; }
    mkdir -p "$ROOT/managed-certificates"
    if [[ -e $LE_DIR/renewal/xray-$domain.conf && ! -e $ROOT/managed-certificates/$domain.json ]]; then
        die '同名 Certbot 证书不是本脚本管理的，拒绝接管。'; return 1
    fi
    jq -n --arg d "$domain" --arg l "$LE_DIR/live/xray-$domain" '{domain:$d,lineage:$l}' | atomic_file "$ROOT/managed-certificates/$domain.json"
    # No manager lock is held while Certbot holds its own lock and invokes hooks.
    ((LOCKED==0)) || { die '内部错误：不能持有配置锁调用 Certbot。'; return; }
    certbot certonly --non-interactive --agree-tos --email "$email" --dns-cloudflare \
        --dns-cloudflare-credentials "$credentials" --dns-cloudflare-propagation-seconds 60 \
        --key-type ecdsa --cert-name "xray-$domain" -d "$domain" --keep-until-expiring \
        --deploy-hook "$MANAGER_ENTRYPOINT cert enqueue" || return
    cert_enqueue "$LE_DIR/live/xray-$domain" || return
    cert_deploy "$domain"
}
cert_enqueue() {
    require_root
    local lineage=${1:-${RENEWED_LINEAGE:-}} domain
    [[ $lineage == "$LE_DIR/live/xray-"* ]] || { die '拒绝非受管证书 lineage。'; return; }
    domain=${lineage#"$LE_DIR/live/xray-"}
    valid_domain "$domain" && [[ -e $ROOT/managed-certificates/$domain.json ]] || { die '未注册的证书。'; return; }
    [[ $(jq -r .lineage "$ROOT/managed-certificates/$domain.json") == "$lineage" ]] || return 1
    mkdir -p "$ROOT/queue"
    jq -n --arg d "$domain" --arg l "$lineage" --arg event "$(random_hex 16)" '{domain:$d,lineage:$l,event:$event}' | atomic_file "$ROOT/queue/$domain.json"
    systemctl start --no-block xray-cert-deploy.service >/dev/null 2>&1 || true
}
cert_validate() {
    local lineage=$1 domain=$2 cert_pub key_pub
    for file in cert.pem chain.pem fullchain.pem privkey.pem; do [[ -s $lineage/$file ]] || { die '证书文件不完整。'; return; }; done
    openssl x509 -in "$lineage/cert.pem" -noout -checkhost "$domain" >/dev/null || return
    openssl x509 -in "$lineage/cert.pem" -noout -checkend 86400 >/dev/null || { die '证书将在一天内到期，拒绝部署。'; return; }
    cert_pub=$(openssl x509 -in "$lineage/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
    key_pub=$(openssl pkey -in "$lineage/privkey.pem" -pubout -outform DER | sha256sum)
    [[ $cert_pub == "$key_pub" ]] || { die '证书与私钥不匹配。'; return; }
    openssl verify -purpose sslserver -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$lineage/chain.pem" "$lineage/cert.pem" >/dev/null
}
cert_deploy_one() {
    local domain=$1 record=$2 lineage fingerprint version issued snapshot nginx_state core_state
    lineage=$(jq -r .lineage "$record")
    [[ $lineage == "$LE_DIR/live/xray-$domain" ]] || return 1
    snapshot=$(mktemp -d "$ROOT/certificate-snapshot.XXXXXX")
    cp -L "$lineage/"{cert,chain,fullchain,privkey}.pem "$snapshot/" || { rm -rf "$snapshot"; return 1; }
    cert_validate "$snapshot" "$domain" || { rm -rf "$snapshot"; return 1; }
    fingerprint=$(openssl x509 -in "$snapshot/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
    version="$ROOT/certificates/$domain/$fingerprint"
    mkdir -p "$version"
    chown "root:$SERVICE_USER" "$ROOT/certificates" "$ROOT/certificates/$domain" "$version"
    chmod 750 "$ROOT/certificates" "$ROOT/certificates/$domain" "$version"
    if [[ ! -e $version/fullchain.pem ]]; then
        install -o root -g "$SERVICE_USER" -m 640 "$snapshot/privkey.pem" "$version/privkey.pem"
        install -o root -g "$SERVICE_USER" -m 640 "$snapshot/fullchain.pem" "$version/fullchain.pem"
        sync_path "$version"
    fi
    issued=$(openssl x509 -in "$snapshot/cert.pem" -noout -enddate | cut -d= -f2-)
    rm -rf "$snapshot"
    lock_state || return
    recover_state || { unlock_state; return 1; }
    load_state
    if [[ $(jq -r --arg d "$domain" '.settings.certificates[$d].fingerprint // ""' <<< "$STATE") != "$fingerprint" ]]; then
        STATE=$(jq --arg d "$domain" --arg path "$version" --arg fp "$fingerprint" --arg expiry "$issued" '.settings.certificates[$d]={path:$path,fingerprint:$fp,expires:$expiry}|.nodes|=map(if .security=="tls" and .endpoint.domain==$d then .inbound_revision+=1 else . end)' <<< "$STATE")
        if ! transaction; then unlock_state; return 1; fi
    fi
    nginx_state=stopped; core_state=stopped
    service_active nginx.service && nginx_state=loaded
    service_active xray-manager.service && core_state=loaded
    mkdir -p "$ROOT/certificate-status"
    jq -n --arg fp "$fingerprint" --arg nginx "$nginx_state" --arg core "$core_state" --argjson state "$STATE" --arg d "$domain" \
        '{fingerprint:$fp,nginx:(if $state.settings.domains|has($d) then $nginx else "unused" end),xray_nodes:[$state.nodes[]|select(.security=="tls" and .endpoint.domain==$d)|{id:.id,state:$core}]}' |
        atomic_file "$ROOT/certificate-status/$domain.json"
    unlock_state
    note "证书已部署：$domain"
}
cert_process() {
    local domain=$1 claim="$ROOT/queue/$1.processing"
    [[ -e $ROOT/queue/$domain.json ]] || return 0
    mv "$ROOT/queue/$domain.json" "$claim" || return
    if cert_deploy_one "$domain" "$claim"; then
        rm -f "$claim" "$ROOT/queue/$domain.error"
    else
        # Never overwrite a newer event written by a concurrent Certbot hook.
        ln "$claim" "$ROOT/queue/$domain.json" 2>/dev/null || true
        rm -f "$claim"
        printf '部署失败，保留上一版本；%s\n' "$(date -u +%FT%TZ)" | atomic_file "$ROOT/queue/$domain.error"
        return 1
    fi
}
cert_deploy() {
    local domain=${1:-} f failed=0 deploy_fd
    exec {deploy_fd}>"$ROOT/certificate-deploy.lock"
    flock -w 30 "$deploy_fd" || { die '另一个证书部署任务正在运行。'; return; }
    # A terminated worker leaves its claimed event recoverable on the next run.
    for f in "$ROOT"/queue/*.processing; do
        [[ -e $f ]] || continue
        ln "$f" "${f%.processing}.json" 2>/dev/null || true
        rm -f "$f"
    done
    if [[ -n $domain ]]; then
        if ! valid_domain "$domain"; then failed=1
        elif [[ -e $ROOT/queue/$domain.json ]]; then cert_process "$domain" || failed=1
        else note '没有待部署证书。'; fi
    else
        for f in "$ROOT"/queue/*.json; do
            [[ -e $f ]] || continue
            domain=$(basename "$f" .json)
            cert_process "$domain" || failed=1
        done
    fi
    flock -u "$deploy_fd"; exec {deploy_fd}>&-
    return "$failed"
}
cert_ensure() {
    local domain=$1 deployed
    load_state
    deployed=$(jq -r --arg d "$domain" '.settings.certificates[$d].path // empty' <<< "$STATE")
    if [[ -n $deployed ]] && openssl x509 -in "$deployed/fullchain.pem" -noout -checkend 604800 >/dev/null; then return; fi
    cert_issue "$domain"
}
cert_list() {
    load_state
    jq -r '.settings.certificates|to_entries[]|[.key,"已提交配置",.value.fingerprint,.value.expires]|@tsv' <<< "$STATE"
    local f domain lineage fp expiry
    for f in "$ROOT"/managed-certificates/*.json; do
        [[ -e $f ]] || continue
        domain=$(basename "$f" .json); lineage=$(jq -r .lineage "$f")
        if [[ -f $lineage/cert.pem ]]; then
            fp=$(openssl x509 -in "$lineage/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
            expiry=$(openssl x509 -in "$lineage/cert.pem" -noout -enddate | cut -d= -f2-)
            printf '%s\t已签发\t%s\t%s\n' "$domain" "$fp" "$expiry"
        fi
        if [[ -f $ROOT/certificate-status/$domain.json ]]; then
            jq -r --arg d "$domain" '[ $d,"上次部署结果",.fingerprint,("nginx="+.nginx),(.xray_nodes|map(.id+"="+.state)|join(","))]|@tsv' "$ROOT/certificate-status/$domain.json"
        fi
    done
    for f in "$ROOT"/queue/*.json; do
        [[ -e $f ]] || continue
        domain=$(basename "$f" .json)
        printf '%s\t待部署%s\n' "$domain" "$([[ -f $ROOT/queue/$domain.error ]] && printf '（上次部署失败）')"
    done
}
cert_renew() {
    local domain=${1:-} f
    ((LOCKED==0)) || return 1
    if [[ -n $domain ]]; then
        valid_domain "$domain" && [[ -e $ROOT/managed-certificates/$domain.json ]] || { die '不是受管证书。'; return; }
        certbot renew --cert-name "xray-$domain" || return
        [[ -e $ROOT/queue/$domain.json ]] && cert_deploy "$domain"
        return 0
    fi
    for f in "$ROOT"/managed-certificates/*.json; do
        [[ -e $f ]] || continue
        cert_renew "$(basename "$f" .json)" || return
    done
}
