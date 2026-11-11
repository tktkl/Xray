export XRAY_MANAGER_HOME=/src
export XRAY_CORE_BIN=/opt/xray-core/xray
export XRAY_ASSET_DIR=/opt/xray-core
export XRAY_TESTING=1
export XRAY_TEST_REALITY_OK=1
setup_manager() {
    export XRAY_MANAGER_ROOT
    XRAY_MANAGER_ROOT=$(mktemp -d /tmp/xray-test.XXXXXX)
    export XRAY_API_SOCKET="$XRAY_MANAGER_ROOT/runtime/api.sock"
    export XRAY_NGINX_LOADER="$XRAY_MANAGER_ROOT/loader.conf"
    mkdir -p "$XRAY_MANAGER_ROOT/test-bin"
    cp /src/tests/fixtures/systemctl "$XRAY_MANAGER_ROOT/test-bin/systemctl"
    chmod +x "$XRAY_MANAGER_ROOT/test-bin/systemctl"
    export PATH="$XRAY_MANAGER_ROOT/test-bin:$PATH"
    source /src/lib/common.sh
    MANAGER_HOME=/src
    for module in store uri protocol render nginx runtime cert install commands; do source "/src/lib/$module.sh"; done
    mkdir -p "$ROOT/logs"
    chown xray-manager:xray-manager "$ROOT/logs"
    mkdir -p "$ROOT/runtime"
    chown xray-manager:xray-manager "$ROOT/runtime"
    lock_state; store_init; load_state; unlock_state
}
teardown_manager() { [[ ! -f $ROOT/core.pid ]] || kill "$(cat "$ROOT/core.pid")" 2>/dev/null || true; rm -rf "$ROOT"; }
manager() { /src/bin/xray "$@"; }
assert_status() { [[ $status == "$1" ]] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; return 1; }; }
