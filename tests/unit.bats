#!/usr/bin/env bats
load helper.bash
setup() { setup_manager; }
teardown() { teardown_manager; }

@test "URI: IPv6 + REALITY share links retain key, SNI and short ID" {
    run outbound_from_uri 'vless://11111111-1111-4111-8111-111111111111@[2001:db8::1]:443?security=reality&type=tcp&sni=xp.apple.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12&flow=xtls-rprx-vision'
    assert_status 0
    [[ $(jq -r '.settings.vnext[0].address' <<< "$output") == 2001:db8::1 ]]
    [[ $(jq -r '.streamSettings.realitySettings.serverName' <<< "$output") == xp.apple.com ]]
}
@test "URI: SS2022 SIP002 round trip and URL-encoded password" {
    local pass auth result
    pass=$(ss_password 2022-blake3-aes-128-gcm)
    auth=$(printf '%s' "2022-blake3-aes-128-gcm:$pass" | openssl base64 -A)
    result=$(outbound_from_uri "ss://$auth@[::1]:23456#test")
    [[ $(jq -r '.settings.servers[0].password' <<< "$result") == "$pass" ]]
    result=$(outbound_from_uri 'ss://aes-128-gcm:p%40ss%3Aword@127.0.0.1:23456')
    [[ $(jq -r '.settings.servers[0].password' <<< "$result") == p@ss:word ]]
}
@test "URI: reject unknown fields, plugin, insecure TLS, malformed percent and duplicate keys" {
    local link
    for link in \
        'ss://YWVzLTEyOC1nY206cGFzcw==@127.0.0.1:1234?plugin=evil' \
        'trojan://pass@127.0.0.1:443?security=tls&allowInsecure=1' \
        'trojan://p%00ass@127.0.0.1:443?security=tls' \
        'trojan://pass@127.0.0.1:443?security=tls&security=none'; do
        run outbound_from_uri "$link"
        [[ $status != 0 ]]
    done
}
@test "Validators reject nginx/shell injection and invalid ports" {
    run valid_domain 'example.com;return 200;'; [[ $status != 0 ]]
    run valid_path '/x;proxy_pass http://evil'; [[ $status != 0 ]]
    run valid_port 65536; [[ $status != 0 ]]
    run uri_decode '%0a'; [[ $status != 0 ]]
    run valid_port 00443; assert_status 0
}
@test "Rendering keeps permanent block first and routes by immutable tags" {
    build_node ss '{}' 23456 auto auto --address 127.0.0.1
    NODE=$(jq '.id="n001"|.name="one"' <<< "$NODE")
    STATE=$(jq --argjson n "$NODE" '.nodes=[$n]' <<< "$STATE")
    new_generation
    [[ $(jq -r '.outbounds[0].tag' "$CANDIDATE/config.json") == block ]]
    [[ $(jq -r '.routing.rules[]|select(.ruleTag=="route-n001-i1-o1")|.outboundTag' "$CANDIDATE/config.json") == out-n001-r1 ]]
    run as_service "$CORE" run -test -c "$CANDIDATE/config.json"
    assert_status 0
}
@test "REALITY uses only configured Apple candidates and nonempty random short ID" {
    build_node reality '{}' 23456 --address 127.0.0.1
    [[ $(jq -r .sni <<< "$NODE") =~ ^(apps.mzstatic.com|xp.apple.com)$ ]]
    [[ $(jq -r .credentials.short_id <<< "$NODE") =~ ^[a-f0-9]{16}$ ]]
    [[ $(jq -r .credentials.private_key <<< "$NODE") != '' ]]
    NODE=$(jq '.id="n001"|.name="one"' <<< "$NODE")
    STATE=$(jq --argjson n "$NODE" '.nodes=[$n]' <<< "$STATE")
    new_generation
    jq -e 'all(.inbounds[].streamSettings.realitySettings; (has("minClientVer")|not) and (has("maxClientVer")|not))' "$CANDIDATE/config.json" >/dev/null
    result=$(client_json "$NODE")
    [[ $(jq -r .streamSettings.realitySettings.publicKey <<< "$result") == "$(jq -r .credentials.public_key <<< "$NODE")" ]]
}
@test "mKCP uses finalmask for new nodes, preserves old native nodes and exports the actual seed" {
    local node client current legacy link
    build_node kcp '{}' 23456 --address 127.0.0.1
    node=$(jq '.id="n001"|.name="one"' <<< "$NODE")
    current=$(client_json "$node")
    jq -e '.streamSettings|(.finalmask.udp[0].type=="mkcp-legacy") and (.kcpSettings|has("seed")|not)' <<< "$current" >/dev/null
    legacy=$(client_json "$node" legacy)
    jq -e '.streamSettings|(.kcpSettings.seed|length)>0 and (has("finalmask")|not)' <<< "$legacy" >/dev/null
    link=$(share_uri "$node"); client=$(base64_decode "${link#vmess://}")
    [[ $(jq -r .path <<< "$client") == "$(jq -r .credentials.seed <<< "$node")" ]]

    node=$(jq 'del(.kcp_compat)' <<< "$node")
    current=$(client_json "$node")
    jq -e '.streamSettings|has("finalmask")|not' <<< "$current" >/dev/null
    run client_json "$node" legacy
    [[ $status != 0 ]]
}
@test "Legacy client export changes JSON layout without installing a version restriction" {
    build_node vws '{}' example.test auto /ws --address 127.0.0.1
    current=$(client_json "$NODE")
    legacy=$(client_json "$NODE" legacy)
    [[ $(jq -r .streamSettings.wsSettings.host <<< "$current") == example.test ]]
    [[ $(jq -r .streamSettings.wsSettings.headers.Host <<< "$legacy") == example.test ]]
    run client_json "$NODE" invalid-profile
    [[ $status != 0 ]]
}
@test "Single-domain nginx output contains independent nodes and public ports" {
    local a b
    build_node vws '{}' example.com auto /one --address 127.0.0.1
    a=$(jq '.id="n001"|.backend.port=20001' <<< "$NODE")
    build_node vgrpc '{}' example.com auto /two --address 127.0.0.1
    b=$(jq '.id="n002"|.backend.port=20002|.endpoint.port=8443' <<< "$NODE")
    STATE=$(jq --argjson a "$a" --argjson b "$b" '.nodes=[$a,$b]|.settings.domains["example.com"]={web:""}|.settings.certificates["example.com"]={path:"/test/cert"}' <<< "$STATE")
    mkdir -p "$ROOT/render/nginx"
    render_nginx "$ROOT/render"
    [[ $(find "$ROOT/render/nginx" -name '*.conf' | wc -l) == 1 ]]
    grep -q 'listen 8443 ssl' "$ROOT/render/nginx/xray-example.com.conf"
    grep -q '127.0.0.1:20001' "$ROOT/render/nginx/xray-example.com.conf"
    grep -q '127.0.0.1:20002' "$ROOT/render/nginx/xray-example.com.conf"
    local url
    url=$(share_uri "$b")
    [[ $url == *@127.0.0.1:8443* && $url != *20002* ]]
}
@test "Certbot hook enqueues without acquiring manager write lock" {
    export XRAY_LE_DIR="$ROOT/letsencrypt"
    LE_DIR=$XRAY_LE_DIR
    mkdir -p "$ROOT/managed-certificates"
    jq -n --arg l "$LE_DIR/live/xray-example.com" '{lineage:$l}' > "$ROOT/managed-certificates/example.com.json"
    lock_state
    run timeout 3 /src/bin/xray cert enqueue "$LE_DIR/live/xray-example.com"
    unlock_state
    assert_status 0
    [[ -f $ROOT/queue/example.com.json ]]
}
@test "Ambiguous names fail noninteractively and stable IDs resolve exactly" {
    STATE='{"nodes":[{"id":"n001","name":"same"},{"id":"n002","name":"same"}]}'
    run node_select same
    [[ $status != 0 ]]
    run node_select n002
    assert_status 0
    [[ $output == n002 ]]
    STATE='{"nodes":[{"id":"n001","name":"first"},{"id":"n002","name":"n001"}]}'
    run node_select n001
    assert_status 0
    [[ $output == n001 ]]
}
@test "Debug redacts both user/pass and VLESS/REALITY credentials" {
    result=$(json_redact <<<'{"id":"n001","pass":"secret","password":"secret","username":"account","private_key":"key","short_id":"ab","seed":"seed","nested":{"auth":"auth"}}')
    [[ $result != *secret* && $result != *account* && $result != *'"ab"'* ]]
}
@test "Log operations cannot follow service-owned symlinks into root-only files" {
    chmod 750 "$ROOT"
    chgrp "$SERVICE_USER" "$ROOT"
    printf 'access event\n' > "$ROOT/logs/access.log"
    printf 'error event\n' > "$ROOT/logs/error.log"
    chown "$SERVICE_USER:$SERVICE_USER" "$ROOT/logs/"*.log
    run command_log log del
    assert_status 0
    [[ ! -s $ROOT/logs/access.log && ! -s $ROOT/logs/error.log ]]

    mkdir "$ROOT/root-private"
    chmod 700 "$ROOT/root-private"
    printf 'ROOT_ONLY_AUDIT_CANARY\n' > "$ROOT/root-private/protected"
    chmod 600 "$ROOT/root-private/protected"
    runuser -u "$SERVICE_USER" -- ln -sf "$ROOT/root-private/protected" "$ROOT/logs/access.log"
    run command_log log del
    [[ $status != 0 ]]
    [[ $(cat "$ROOT/root-private/protected") == ROOT_ONLY_AUDIT_CANARY ]]
    run timeout 1 /src/bin/xray log
    [[ $status == 124 && $output != *ROOT_ONLY_AUDIT_CANARY* ]]
}
@test "Common Trojan links imply TLS and VMess round trip preserves transport" {
    run outbound_from_uri 'trojan://p%40ss@example.test:443?sni=example.test'
    assert_status 0
    [[ $(jq -r .streamSettings.security <<< "$output") == tls ]]
    build_node ws '{}' example.test auto /ws --address 127.0.0.1
    NODE=$(jq '.id="n001"|.name="fixture"' <<< "$NODE")
    link=$(share_uri "$NODE")
    run outbound_from_uri "$link"
    assert_status 0
    [[ $(jq -r .streamSettings.wsSettings.path <<< "$output") == /ws ]]
}
@test "Certificate queue restores an interrupted claimed deployment" {
    printf '{"domain":"example.test","lineage":"/missing"}' > "$ROOT/queue/example.test.processing"
    run cert_deploy example.test
    [[ $status != 0 ]]
    [[ -e $ROOT/queue/example.test.json && -e $ROOT/queue/example.test.error ]]
    [[ ! -e $ROOT/queue/example.test.processing ]]
}
