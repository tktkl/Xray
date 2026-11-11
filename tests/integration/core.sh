#!/usr/bin/env bash
set -Eeuo pipefail
source /src/tests/helper.bash
setup_manager
PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    teardown_manager
}
trap cleanup EXIT
trap 'printf "FAILED at line %s\n" "$LINENO" >&2; cat "$ROOT"/core.log 2>/dev/null || true' ERR
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; return 1; }; }
ip address add 8.8.4.4/32 dev lo
ip address add 114.114.114.114/32 dev lo
python3 /src/tests/fixtures/echo.py & PIDS+=("$!")
for port in 22441 22442 22443; do manager a reality "$port" --address 127.0.0.1 >/dev/null; done
assert test "$(find "$ROOT/current/nodes" -name '*.json' | wc -l)" = 3
assert test "$(jq -s '[.[].credentials.private_key]|unique|length' "$ROOT/current/nodes/"*.json)" = 3
manager a socks 22444 tester test-password --address 127.0.0.1 >/dev/null
runuser -u xray-manager -- env XRAY_LOCATION_ASSET=/opt/xray-core "$CORE" run -c "$ROOT/current/config.json" > "$ROOT/core.log" 2>&1 &
printf '%s\n' "$!" > "$ROOT/core.pid"
wait_api
pid_before=$(cat "$ROOT/core.pid")
direct=$(curl --fail --silent --show-error --max-time 5 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080)
assert test -n "$direct"
curl --silent --show-error --no-buffer --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080/stream > "$ROOT/stream" & stream_pid=$!; PIDS+=("$stream_pid")
sleep .5
manager port n001 22445 >/dev/null
manager id n002 auto >/dev/null
manager new n003 ss >/dev/null
assert kill -0 "$stream_pid"
assert test "$(cat "$ROOT/core.pid")" = "$pid_before"
assert test "$(wc -l < "$ROOT/stream")" -ge 3
assert test "$(jq -r .protocol "$ROOT/current/nodes/n003.json")" = Shadowsocks
assert test "$(jq -r .outbound.protocol "$ROOT/current/nodes/n003.json")" = freedom
printf 'PASS: multiple nodes, isolated changes and uninterrupted stream\n'

# Independent, real SS and VLESS upstreams. Source addresses prove which exit
# actually performed the final connection; these are fixture server processes.
sspass=$(ss_password 2022-blake3-aes-128-gcm)
vlessid=$(uuid)
jq -n --arg pass "$sspass" --arg id "$vlessid" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:22551,tag:"ss",protocol:"shadowsocks",settings:{method:"2022-blake3-aes-128-gcm",password:$pass,network:"tcp,udp"}},{listen:"127.0.0.1",port:22552,tag:"vless",protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"}}],outbounds:[{tag:"ss-exit",protocol:"freedom",sendThrough:"127.0.0.2"},{tag:"vless-exit",protocol:"freedom",sendThrough:"127.0.0.3"}],routing:{rules:[{type:"field",inboundTag:["ss"],outboundTag:"ss-exit"},{type:"field",inboundTag:["vless"],outboundTag:"vless-exit"}]}}' > "$ROOT/upstream.json"
jq '.inbounds += [{listen:"127.0.0.1",port:22553,tag:"socks",protocol:"socks",settings:{auth:"password",accounts:[{user:"exit",pass:"secret"}],udp:true}},{listen:"127.0.0.1",port:22554,tag:"http",protocol:"http",settings:{accounts:[{user:"exit",pass:"secret"}]}}]|.routing.rules += [{type:"field",inboundTag:["socks","http"],outboundTag:"vless-exit"}]' "$ROOT/upstream.json" > "$ROOT/upstream-next.json"
mv "$ROOT/upstream-next.json" "$ROOT/upstream.json"
"$CORE" run -c "$ROOT/upstream.json" > "$ROOT/upstream.log" 2>&1 & PIDS+=("$!")
sleep .5
auth=$(printf '%s' "2022-blake3-aes-128-gcm:$sspass" | openssl base64 -A)
manager ob n004 "ss://$auth@127.0.0.1:22551" >/dev/null
ss_exit=$(curl --fail --silent --max-time 5 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080)
assert test "$ss_exit" = 127.0.0.2
manager ob n004 "vless://$vlessid@127.0.0.1:22552?encryption=none&security=none&type=tcp" >/dev/null
vless_exit=$(curl --fail --silent --max-time 5 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080)
assert test "$vless_exit" = 127.0.0.3
for link in socks5://exit:secret@127.0.0.1:22553 http://exit:secret@127.0.0.1:22554; do
    manager ob n004 "$link" >/dev/null
    actual=$(curl --fail --silent --max-time 5 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080)
    assert test "$actual" = 127.0.0.3
done
assert kill -0 "$stream_pid"
manager ob n004 "vless://$vlessid@127.0.0.1:22559?encryption=none&security=none&type=tcp" >/dev/null
if curl --fail --silent --max-time 2 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080 >/dev/null; then printf 'Unexpected direct fallback\n' >&2; exit 1; fi
manager ob n004 direct >/dev/null
printf 'PASS: real SS/VLESS exits and no direct fallback\n'

# Literal private and CN targets, and domain->CN resolution, must be rejected.
for address in 127.0.0.1 114.114.114.114; do
    if curl --fail --silent --max-time 2 --proxy socks5h://tester:test-password@127.0.0.1:22444 "http://$address:18080" >/dev/null; then exit 1; fi
done
printf '114.114.114.114 cn-block.example.test\n' >> /etc/hosts
if curl --fail --silent --max-time 2 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://cn-block.example.test:18080 >/dev/null; then exit 1; fi
printf 'PASS: private/CN and resolved-domain blocking\n'
python3 /src/tests/fixtures/bt_client.py

# Lost API response must be reconciled by queries, not blindly replayed.
XRAY_CORE_BIN=/src/tests/fixtures/core-api XRAY_TEST_API_MODE=after XRAY_TEST_API_COMMAND=adrules manager port n001 24601 >/dev/null
assert test "$(jq -r .endpoint.port "$ROOT/current/nodes/n001.json")" = 24601
before=$(readlink -f "$ROOT/current")
if XRAY_CORE_BIN=/src/tests/fixtures/core-api XRAY_TEST_API_MODE=before XRAY_TEST_API_COMMAND=adi manager port n001 24602 >/dev/null 2>&1; then exit 1; fi
assert test "$(readlink -f "$ROOT/current")" = "$before"
assert test ! -e "$ROOT/transaction.json"
rm -f "$ROOT/api-fault-before"
before=$(readlink -f "$ROOT/current")
if XRAY_CORE_BIN=/src/tests/fixtures/core-api XRAY_TEST_API_MODE=before XRAY_TEST_API_COMMAND=adrules manager port n001 24603 >/dev/null 2>&1; then exit 1; fi
assert test "$(readlink -f "$ROOT/current")" = "$before"
assert test ! -e "$ROOT/transaction.json"
assert kill -0 "$stream_pid"
printf 'PASS: lost API reply reconciliation and failed inbound rollback\n'

# Crash at each operation boundary: recover old before commit, retain new after.
for phase in prepared outbounds inbounds routes nginx applied committed; do
    before=$(readlink -f "$ROOT/current")
    if XRAY_TEST_FAULT=$phase manager port n001 "$(shuf -i 24000-25000 -n1)" >/dev/null 2>&1; then exit 1; fi
    [[ -f $ROOT/transaction.json ]]
    manager recover >/dev/null
    [[ ! -f $ROOT/transaction.json ]]
    after=$(readlink -f "$ROOT/current")
    if [[ $phase == committed ]]; then assert test "$before" != "$after"; else assert test "$before" = "$after"; fi
    assert kill -0 "$stream_pid"
done
if grep -q 'restart xray-manager' "$ROOT/systemctl-calls" 2>/dev/null; then exit 1; fi
printf 'PASS: seven crash boundaries, durable recovery, no core restart\n'

manager d n001 >/dev/null
assert test -f "$ROOT/current/nodes/n004.json"
assert test ! -e "$ROOT/current/nodes/n001.json"
curl --fail --silent --max-time 5 --proxy socks5h://tester:test-password@127.0.0.1:22444 http://8.8.4.4:18080 >/dev/null
printf 'PASS: deleting one node leaves other nodes operational\n'
