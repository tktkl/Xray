#!/usr/bin/env bash
set -Eeuo pipefail
source /src/tests/helper.bash
setup_manager
export XRAY_NGINX_LOADER=/etc/nginx/conf.d/xray-manager.conf
NGINX_LOADER=$XRAY_NGINX_LOADER
export XRAY_LE_DIR="$ROOT/letsencrypt"
LE_DIR=$XRAY_LE_DIR
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; nginx -s stop 2>/dev/null || true; rm -f /etc/nginx/conf.d/{xray-manager,test-target}.conf; teardown_manager; }
trap cleanup EXIT
trap 'echo "::error title=TLS integration failed::line $LINENO, status $?" >&2' ERR
lineage="$LE_DIR/live/xray-example.test"
mkdir -p "$lineage" "$ROOT/managed-certificates"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=Xray-Test-CA -keyout "$ROOT/ca.key" -out "$ROOT/ca.crt" >/dev/null 2>&1
cp "$ROOT/ca.crt" /usr/local/share/ca-certificates/xray-test.crt
update-ca-certificates >/dev/null 2>&1
make_leaf() {
    openssl req -newkey rsa:2048 -nodes -subj /CN=example.test -keyout "$lineage/privkey.pem" -out "$ROOT/leaf.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:example.test,DNS:apps.mzstatic.com,DNS:xp.apple.com\nextendedKeyUsage=serverAuth\n' > "$ROOT/leaf.ext"
    openssl x509 -req -in "$ROOT/leaf.csr" -CA "$ROOT/ca.crt" -CAkey "$ROOT/ca.key" -CAcreateserial -days 30 -extfile "$ROOT/leaf.ext" -out "$lineage/cert.pem" >/dev/null 2>&1
    cp "$ROOT/ca.crt" "$lineage/chain.pem"
    cat "$lineage/cert.pem" "$lineage/chain.pem" > "$lineage/fullchain.pem"
}
make_leaf
jq -n --arg l "$lineage" '{lineage:$l,domain:"example.test"}' > "$ROOT/managed-certificates/example.test.json"
manager cert enqueue "$lineage"
manager cert deploy example.test
nginx_install_loader
cat > /etc/nginx/conf.d/test-target.conf <<EOF
server {
  listen 443 ssl http2 default_server;
  server_name apps.mzstatic.com xp.apple.com;
  ssl_certificate $lineage/fullchain.pem;
  ssl_certificate_key $lineage/privkey.pem;
  return 200 'target';
}
EOF
nginx
manager a vws example.test auto /one --address 127.0.0.1 >/dev/null
manager a vgrpc example.test auto /two --address 127.0.0.1 >/dev/null
manager a xhttp example.test auto /three --address 127.0.0.1 >/dev/null
runuser -u xray-manager -- env XRAY_LOCATION_ASSET=/opt/xray-core "$CORE" run -c "$ROOT/current/config.json" > "$ROOT/core.log" 2>&1 &
printf '%s\n' "$!" > "$ROOT/core.pid"
wait_api
[[ $(find "$ROOT/current/nginx" -name '*.conf' | wc -l) == 1 ]]
manager port n001 8443 >/dev/null
grep -q 'listen 8443 ssl' "$ROOT/current/nginx/xray-example.test.conf"
[[ $(jq -r .endpoint.port "$ROOT/current/nodes/n002.json") == 443 ]]
if manager path n002 /three >/dev/null 2>&1; then echo 'path conflict accepted' >&2; exit 1; fi
nginx -t
curl --fail --silent --show-error --resolve example.test:443:127.0.0.1 https://example.test/ | grep -q Welcome
first=$(jq -r '.certificates["example.test"].fingerprint' "$ROOT/current/settings.json")
make_leaf
manager cert enqueue "$lineage"
manager cert deploy example.test
second=$(jq -r '.certificates["example.test"].fingerprint' "$ROOT/current/settings.json")
[[ $first != "$second" && ! -e $ROOT/queue/example.test.json ]]
live=$(openssl s_client -connect 127.0.0.1:443 -servername example.test </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr A-F a-f)
[[ $live == "$second" ]]
# A bad new private key must not replace the deployed version, and remains queued.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$lineage/privkey.pem" >/dev/null 2>&1
manager cert enqueue "$lineage"
if manager cert deploy example.test >/dev/null 2>&1; then exit 1; fi
[[ -e $ROOT/queue/example.test.json && -e $ROOT/queue/example.test.error ]]
[[ $(jq -r '.certificates["example.test"].fingerprint' "$ROOT/current/settings.json") == "$second" ]]
printf 'PASS: one domain/one file, isolated public ports, path validation, real nginx TLS, renewal and failed-deployment preservation\n'

# Build real clients for every advertised protocol and transfer through nginx
# (or directly for REALITY/Hysteria/SS/mKCP).
make_leaf
manager cert enqueue "$lineage"
manager cert deploy example.test
printf '127.0.0.1 example.test apps.mzstatic.com xp.apple.com\n' >> /etc/hosts
ip address add 8.8.4.4/32 dev lo 2>/dev/null || true
python3 /src/tests/fixtures/echo.py & PIDS+=("$!")
for protocol in ws grpc tws tgrpc; do manager a "$protocol" example.test auto "/$protocol" --address 127.0.0.1 >/dev/null; done
manager a hy2 24551 hy-secret --domain example.test --address 127.0.0.1 >/dev/null
manager a tcp 24552 --address 127.0.0.1 >/dev/null
manager a kcp 24553 --address 127.0.0.1 >/dev/null
manager a ss 24554 --address 127.0.0.1 >/dev/null
manager a reality 24555 --address 127.0.0.1 >/dev/null
manager a ss 24556 auto chacha20-ietf-poly1305 --address 127.0.0.1 >/dev/null
port=25001
for file in "$ROOT/current/nodes/"*.json; do
    id=$(jq -r .id "$file"); protocol=$(jq -r .protocol "$file")
    manager genc "$id" | jq --argjson p "$port" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}],outbounds:[.]}' > "$ROOT/client-$id.json"
    "$CORE" run -c "$ROOT/client-$id.json" > "$ROOT/client-$id.log" 2>&1 & client_pid=$!; PIDS+=("$client_pid")
    sleep .3
    if ! curl --fail --silent --show-error --max-time 8 --proxy "socks5h://127.0.0.1:$port" http://8.8.4.4:18080 >/dev/null; then
        cat "$ROOT/client-$id.log" "$ROOT/core.log" >&2; exit 1
    fi
    python3 /src/tests/fixtures/udp_client.py "$port" || { cat "$ROOT/client-$id.log" >&2; exit 1; }
    if [[ $id == n001 ]]; then
        curl --silent --no-buffer --proxy "socks5h://127.0.0.1:$port" http://8.8.4.4:18080/stream > "$ROOT/tls-stream" & stream_pid=$!; PIDS+=("$stream_pid")
        sleep .5
        manager port n002 8444 >/dev/null
        make_leaf
        manager cert enqueue "$lineage"
        manager cert deploy example.test
        kill -0 "$stream_pid"
        [[ $(wc -l < "$ROOT/tls-stream") -ge 4 ]]
        kill "$stream_pid"; wait "$stream_pid" || true
        printf 'PASS: nginx reload and certificate renewal preserve another node stream\n'
    fi
    if [[ $protocol == VLESS-XHTTP-TLS ]]; then
        curl --silent --no-buffer --max-time 2 --proxy "socks5h://127.0.0.1:$port" http://8.8.4.4:18080/stream > "$ROOT/xhttp-stream" || [[ $? == 28 ]]
        [[ $(wc -l < "$ROOT/xhttp-stream") -ge 5 ]]
        printf 'PASS: XHTTP streaming responses arrive without full-response buffering\n'
    fi
    printf 'PASS: real %s client TCP/UDP round trip\n' "$protocol"
    kill "$client_pid"; wait "$client_pid" || true
    ((port+=1))
    for client in /opt/xray-clients/*/xray; do
        [[ -x $client ]] || continue
        client_version=$(basename "$(dirname "$client")")
        case $protocol in
            Hysteria2) continue;;
            VLESS-XHTTP-TLS) [[ $client_version == v24.12.31 ]] || continue;;
        esac
        manager genc "$id" legacy | jq --argjson p "$port" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}],outbounds:[.]}' > "$ROOT/legacy-$id.json"
        "$client" run -test -c "$ROOT/legacy-$id.json" > "$ROOT/legacy-$id.log" 2>&1 || { cat "$ROOT/legacy-$id.log" >&2; exit 1; }
        "$client" run -c "$ROOT/legacy-$id.json" > "$ROOT/legacy-$id.log" 2>&1 & client_pid=$!; PIDS+=("$client_pid")
        sleep .3
        if [[ $protocol == VLESS-REALITY ]]; then
            # The pinned upstream REALITY implementation rejects ClientHello
            # without X25519MLKEM768 before it checks optional version bounds.
            if curl --fail --silent --show-error --max-time 3 --proxy "socks5h://127.0.0.1:$port" http://8.8.4.4:18080 >/dev/null 2>&1; then
                printf 'Unexpected old REALITY handshake result; review pinned-core compatibility boundary.\n' >&2; exit 1
            fi
            printf 'EXPECTED BOUNDARY: %s REALITY config parses, upstream core rejects old TLS ClientHello\n' "$client_version"
            kill "$client_pid"; wait "$client_pid" || true
            ((port+=1)); continue
        fi
        if ! curl --fail --silent --show-error --max-time 8 --proxy "socks5h://127.0.0.1:$port" http://8.8.4.4:18080 >/dev/null; then
            printf 'FAIL: %s client -> %s server\n' "$client_version" "$protocol" >&2
            cat "$ROOT/legacy-$id.log" "$ROOT/core.log" >&2; exit 1
        fi
        python3 /src/tests/fixtures/udp_client.py "$port" || { cat "$ROOT/legacy-$id.log" >&2; exit 1; }
        printf 'PASS: %s client -> current %s server TCP/UDP\n' "$client_version" "$protocol"
        kill "$client_pid"; wait "$client_pid" || true
        ((port+=1))
    done
done
