#!/usr/bin/env bash
render_nginx() {
    local generation=$1 domain port cert web node kind path backend
    local -a ports=()
    while IFS= read -r domain; do
        [[ -n $domain ]] || continue
        valid_domain "$domain" || { die '非法受管域名。'; return; }
        cert=$(jq -r --arg d "$domain" '.settings.certificates[$d].path // empty' <<< "$STATE")
        [[ -n $cert ]] || { die "域名尚未部署证书：$domain"; return; }
        web=$(jq -r --arg d "$domain" '.settings.domains[$d].web // ""' <<< "$STATE")
        mapfile -t ports < <(jq -r --arg d "$domain" '([443]+[.nodes[]|select(.security=="nginx" and .endpoint.domain==$d)|.endpoint.port])|unique[]' <<< "$STATE")
        {
            printf '# Managed domain: %s\n' "$domain"
            printf 'server {\n  listen 80;\n  server_name %s;\n  return 301 https://$host$request_uri;\n}\n' "$domain"
            for port in "${ports[@]}"; do
                printf 'server {\n  listen %s ssl http2;\n  server_name %s;\n' "$port" "$domain"
                if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]; then
                    printf '  listen [::]:%s ssl http2;\n' "$port"
                fi
                printf '  ssl_certificate %s/fullchain.pem;\n  ssl_certificate_key %s/privkey.pem;\n  ssl_protocols TLSv1.2 TLSv1.3;\n' "$cert" "$cert"
                while IFS= read -r node; do
                    path=$(jq -r .endpoint.path <<< "$node"); backend=$(jq -r .backend.port <<< "$node"); kind=$(jq -r .network <<< "$node")
                    case $kind in
                        ws)
                            printf '  location = %s {\n    proxy_pass http://127.0.0.1:%s;\n    proxy_http_version 1.1;\n    proxy_set_header Upgrade $http_upgrade;\n    proxy_set_header Connection "upgrade";\n    proxy_set_header Host $host;\n    proxy_read_timeout 1d;\n    proxy_buffering off;\n  }\n' "$path" "$backend";;
                        grpc)
                            printf '  location ^~ %s/ {\n    grpc_pass grpc://127.0.0.1:%s;\n    grpc_read_timeout 1d;\n    grpc_send_timeout 1d;\n    client_max_body_size 0;\n  }\n' "$path" "$backend";;
                        xhttp)
                            printf '  location ^~ %s/ {\n    proxy_pass http://127.0.0.1:%s;\n    proxy_http_version 1.1;\n    proxy_set_header Connection "";\n    proxy_set_header Host $host;\n    proxy_buffering off;\n    proxy_request_buffering off;\n    proxy_read_timeout 1d;\n    proxy_send_timeout 1d;\n    client_max_body_size 0;\n  }\n' "${path%/}" "$backend";;
                    esac
                done < <(jq -c --arg d "$domain" --argjson p "$port" '.nodes[]|select(.security=="nginx" and .endpoint.domain==$d and .endpoint.port==$p)' <<< "$STATE")
                if [[ -z $web ]]; then
                    printf '  location / {\n    default_type text/html;\n    return 200 "<!doctype html><html><title>Welcome</title><body><h1>Welcome</h1></body></html>";\n  }\n'
                else
                    printf '  location / {\n    proxy_pass https://%s;\n    proxy_ssl_server_name on;\n    proxy_ssl_name %s;\n    proxy_set_header Host %s;\n    proxy_ssl_verify on;\n    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n  }\n' "$web" "$web" "$web"
                fi
                printf '}\n'
            done
        } > "$generation/nginx/xray-$domain.conf"
    done < <(jq -r '.settings.domains|keys[]' <<< "$STATE")
}
nginx_shadow_test() {
    local generation=$1 tmp conf
    [[ -e $NGINX_LOADER ]] || { die 'Nginx 管理 include 尚未安装。'; return; }
    tmp=$(mktemp -d "$ROOT/nginx-test.XXXXXX")
    # Expand all includes with nginx itself, then replace ONLY our loader contents.
    # -T output marks file boundaries. A flattened config cannot preserve contexts;
    # instead copy the actual configuration tree and rewrite absolute /etc/nginx paths.
    cp -a /etc/nginx "$tmp/nginx"
    conf="$tmp/nginx/$(basename "$NGINX_MAIN")"
    if [[ $NGINX_MAIN != /etc/nginx/nginx.conf ]]; then cp "$NGINX_MAIN" "$conf"; fi
    while IFS= read -r -d '' f; do
        [[ -L $f ]] && continue
        sed -i "s|/etc/nginx/|$tmp/nginx/|g" "$f"
    done < <(find "$tmp/nginx" -type f -print0)
    # Resolve symlinks in sites-enabled to the shadow tree, never mutate originals.
    while IFS= read -r -d '' f; do
        local dest
        dest=$(readlink -f "$f")
        if [[ $dest == /etc/nginx/* ]]; then ln -sfn "$tmp/nginx/${dest#/etc/nginx/}" "$f"; fi
    done < <(find "$tmp/nginx" -type l -print0)
    printf 'include %s/nginx/*.conf;\n' "$generation" > "$tmp/nginx/conf.d/xray-manager.conf"
    if nginx -t -c "$conf" > "$tmp/output" 2>&1 && ! grep -q 'conflicting server name' "$tmp/output"; then rm -rf -- "$tmp"; return 0; fi
    cat "$tmp/output" >&2
    rm -rf -- "$tmp"
    return 1
}
nginx_install_loader() {
    if [[ -e $NGINX_LOADER ]]; then
        grep -Fq "include $ROOT/installed/nginx/*.conf;" "$NGINX_LOADER" || { die 'Nginx include 路径已被其他应用使用。'; return; }
    else
        printf 'include %s/installed/nginx/*.conf;\n' "$ROOT" > "$NGINX_LOADER"
        chmod 644 "$NGINX_LOADER"
    fi
}
nginx_apply() {
    local generation=$1
    atomic_link "$generation" "$ROOT/installed"
    [[ -e $NGINX_LOADER ]] || return 0
    nginx -t >/dev/null 2>&1 || return 1
    if service_active nginx.service; then
        systemctl reload nginx.service || return
        nginx_verify_certificates "$generation" || return
    fi
}
nginx_verify_certificates() {
    local generation=$1 domain port path expected actual attempt
    while IFS=$'\t' read -r domain path; do
        expected=$(openssl x509 -in "$path/fullchain.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':') || return
        while IFS= read -r port; do
            actual=''
            for ((attempt=0;attempt<20;attempt++)); do
                actual=$(timeout 3 openssl s_client -connect "127.0.0.1:$port" -servername "$domain" </dev/null 2>/dev/null |
                    openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':') || true
                [[ $actual != "$expected" ]] || break
                sleep .1
            done
            [[ $actual == "$expected" ]] || { die "Nginx 尚未加载预期证书：$domain:$port"; return; }
        done < <({ echo 443; for f in "$generation"/nodes/*.json; do [[ ! -e $f ]] || jq -r --arg d "$domain" 'select(.security=="nginx" and .endpoint.domain==$d)|.endpoint.port' "$f"; done; } | sort -un)
    done < <(jq -r '. as $s|.domains|keys[]|[.,$s.certificates[.].path]|@tsv' "$generation/settings.json")
}
