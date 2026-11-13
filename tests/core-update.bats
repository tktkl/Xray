#!/usr/bin/env bats
load helper.bash
setup() {
    setup_manager
    cp /src/tests/fixtures/core-curl "$ROOT/test-bin/curl"
    chmod +x "$ROOT/test-bin/curl"
    export CORE_RELEASE_REQUESTS="$ROOT/core-requests"
    export CORE_RELEASE_FIXTURE="$ROOT/release"
    mkdir "$CORE_RELEASE_FIXTURE"
    case $(uname -m) in x86_64) asset=Xray-linux-64.zip;; *) asset=Xray-linux-arm64-v8a.zip;; esac
}
teardown() { teardown_manager; }
field_fixture() {
    MANAGER_HOME="$ROOT/home"
    mkdir -p "$MANAGER_HOME/config" "$MANAGER_HOME/lib" "$ROOT/source/Xray-core-26.11.9/infra/conf"
    cp /src/lib/core-fields.awk "$MANAGER_HOME/lib/"
    cp /src/config/releases.json "$MANAGER_HOME/config/"
    printf '%s\n' '{"version":"v0.0.0","fields":["xray.go:Config.log","xray.go:Config.removed"]}' > "$MANAGER_HOME/config/core-fields.json"
    cat > "$ROOT/source/Xray-core-26.11.9/infra/conf/xray.go" <<'EOF'
package conf
// type Ignored struct { Fake string `json:"commented"` }
/* Fake string `json:"multiline"`
   More string `json:"alsoIgnored"` */
type Config struct {
    Log string `json:"log,omitempty"`
    Added bool `json:"newFeature"`
    Hidden string `json:"-"`
}
EOF
    tar -czf "$CORE_RELEASE_FIXTURE/source.tar.gz" -C "$ROOT/source" Xray-core-26.11.9
}

@test "Core update: latest resolves only official stable version tags and fails on network errors" {
    run latest_core_version
    assert_status 0
    [[ $output == v26.11.9 ]]
    for destination in '' 'https://github.com/XTLS/Xray-core/releases/tag/main' \
        'https://github.com/evil/Xray-core/releases/tag/v1.2.3' \
        'https://github.com/XTLS/Xray-core/releases/tag/v1.2.3-rc1'; do
        export CORE_LATEST_URL="$destination"
        run latest_core_version
        [[ $status != 0 && $output == *地址无效* ]]
    done
    export CORE_HTTP_FAIL=latest
    run latest_core_version
    [[ $status != 0 && $output == *无法查询* ]]
}

@test "Core update: versions outside bundled manifest use the official SHA256 instead of a whitelist" {
    field_fixture
    jq '.core={}' "$MANAGER_HOME/config/releases.json" > "$ROOT/manifest"
    mv "$ROOT/manifest" "$MANAGER_HOME/config/releases.json"
    info=$(core_release_info v26.11.9)
    [[ $(jq -r .tested <<< "$info") == false ]]
    [[ $(jq -r .sha256 <<< "$info") == "$(sha256sum "/src/.cache/$asset" | awk '{print $1}')" ]]
    run core_fetch_binary "$info" "$ROOT/downloaded"
    assert_status 0
    [[ $(core_version "$ROOT/downloaded/xray") == v26.11.9 ]]
    [[ $(wc -l < "$CORE_RELEASE_REQUESTS") == 2 ]]
}

@test "Core update: malformed or duplicate official digests and wrong binary checksums fail" {
    field_fixture
    jq '.core={}' "$MANAGER_HOME/config/releases.json" > "$ROOT/manifest"
    mv "$ROOT/manifest" "$MANAGER_HOME/config/releases.json"
    printf 'SHA2-256= broken\n' > "$CORE_RELEASE_FIXTURE/$asset.dgst"
    run core_release_info v26.11.9
    [[ $status != 0 && $output == *SHA256* ]]
    printf 'SHA2-256= %064d\nSHA2-256= %064d\n' 0 0 > "$CORE_RELEASE_FIXTURE/$asset.dgst"
    run core_release_info v26.11.9
    [[ $status != 0 && $output == *SHA256* ]]
    printf 'SHA2-256= %064d\n' 0 > "$CORE_RELEASE_FIXTURE/$asset.dgst"
    info=$(core_release_info v26.11.9)
    run core_fetch_binary "$info" "$ROOT/downloaded"
    [[ $status != 0 && ! -e $ROOT/downloaded/xray ]]
}

@test "Core update: added JSON fields are displayed and recorded without importing upstream code" {
    field_fixture
    info=$(core_release_info v26.11.9)
    run core_field_report "$info"
    assert_status 0
    [[ $output == *发现\ 1\ 个新增* && $output == *Config.newFeature* ]]
    [[ $output == *不会自动写入节点* ]]
    jq -e '.added==["xray.go:Config.newFeature"] and .removed==["xray.go:Config.removed"]' \
        "$ROOT/core-reports/v26.11.9.json" >/dev/null
    [[ $output != *commented* && $output != *alsoIgnored* ]]
    [[ ! -e $ROOT/systemctl-calls ]]
}

@test "Core update: field inspection failures and unsafe source archives stop before replacement" {
    field_fixture
    info=$(core_release_info v26.11.9)
    before=$(sha256sum "$CORE")
    export CORE_HTTP_FAIL=source
    run core_field_report "$info"
    [[ $status != 0 && $output == *无法完成新字段检查* ]]
    unset CORE_HTTP_FAIL
    tar -czf "$CORE_RELEASE_FIXTURE/source.tar.gz" --transform='s|Xray-core-26.11.9|../outside|' -C "$ROOT/source" Xray-core-26.11.9
    run core_field_report "$info"
    [[ $status != 0 && $output == *不安全路径* ]]
    [[ $(sha256sum "$CORE") == "$before" && ! -e $ROOT/core-reports/v26.11.9.json ]]
    [[ ! -e $ROOT/outside && ! -e $ROOT/systemctl-calls ]]
}

@test "Core update: already latest leaves core and node configuration untouched" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    before=$(sha256sum "$CORE")
    generation=$(readlink -f "$ROOT/current")
    run manager update core
    assert_status 0
    [[ $output == *已是官方最新正式版* ]]
    [[ $(sha256sum "$CORE") == "$before" && $(readlink -f "$ROOT/current") == "$generation" ]]
    [[ ! -e $ROOT/core-upgrade.json && ! -e $ROOT/systemctl-calls ]]
}

@test "Core update: check-only runs real candidate config and Unix-socket mutation APIs without replacing core" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    before=$(sha256sum "$CORE")
    generation=$(readlink -f "$ROOT/current")
    run manager update core --check
    assert_status 0
    [[ $output == *现有配置及管理\ API\ 检查通过* ]]
    [[ $(sha256sum "$CORE") == "$before" && $(readlink -f "$ROOT/current") == "$generation" ]]
    [[ ! -e $ROOT/core-upgrade.json && ! -e $ROOT/systemctl-calls ]]
    [[ $(find "$ROOT" -maxdepth 1 -name 'core-update.*' | wc -l) == 0 ]]
}

@test "Core update: invalid command arguments never trigger a release query" {
    run manager update core main
    [[ $status != 0 && $output == *核心版本必须* ]]
    run manager update core --unknown
    [[ $status != 0 && $output == *用法* ]]
    [[ ! -e $CORE_RELEASE_REQUESTS && ! -e $ROOT/core-upgrade.json ]]
}

@test "Core update: binary version mismatch and removed APIs fail before touching the running core" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    before=$(sha256sum "$CORE")
    generation=$(readlink -f "$ROOT/current")
    core_fetch_binary() {
        mkdir -p "$2"
        cat > "$2/xray" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == version ]]; then printf 'Xray 0.0.0\n'; exit; fi
exec /opt/xray-core/xray "$@"
EOF
        chmod 755 "$2/xray"
    }
    run update_core v26.11.9 --check
    [[ $status != 0 && $output == *实际版本与发布标签不一致* ]]
    core_fetch_binary() {
        mkdir -p "$2"
        cat > "$2/xray" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == api && ${2:-} == adrules ]]; then exit 1; fi
exec /opt/xray-core/xray "$@"
EOF
        chmod 755 "$2/xray"
    }
    run update_core v26.11.9 --check
    [[ $status != 0 && $output == *API\ 验证失败* ]]
    [[ $(sha256sum "$CORE") == "$before" && $(readlink -f "$ROOT/current") == "$generation" ]]
    [[ ! -e $ROOT/core-upgrade.json && ! -e $ROOT/systemctl-calls ]]
}

@test "Core update: probe configuration stays root-owned while only the socket directory is writable" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    run core_api_probe "$CORE" "$ROOT/probe"
    assert_status 0
    [[ $(stat -c '%U:%G:%a' "$ROOT/probe/config.json") == root:xray-manager:640 ]]
    [[ $(stat -c '%U:%a' "$ROOT/probe") == root:750 ]]
    [[ $(stat -c '%U:%a' "$ROOT/probe/runtime") == xray-manager:700 ]]
    run runuser -u "$SERVICE_USER" -- test -w "$ROOT/probe/config.json"
    [[ $status != 0 ]]
    run runuser -u "$SERVICE_USER" -- test -w "$ROOT/probe"
    [[ $status != 0 ]]
}

@test "Core recovery: failed binary restoration preserves the durable recovery record" {
    mkdir "$ROOT/core-backups"
    cp "$CORE" "$ROOT/core-backups/previous"
    jq -n --arg previous "$ROOT/core-backups/previous" '{previous:$previous,was_running:false}' > "$ROOT/core-upgrade.json"
    CORE="$ROOT/missing-directory/xray"
    run recover_state offline
    [[ $status != 0 && -f $ROOT/core-upgrade.json ]]
    [[ ! -e $ROOT/systemctl-calls ]]
}
