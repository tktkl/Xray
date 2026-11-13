#!/usr/bin/env bats
load helper.bash
setup() {
    setup_manager
    cp /src/tests/fixtures/release-curl "$ROOT/test-bin/curl"
    chmod +x "$ROOT/test-bin/curl"
    export BOOTSTRAP_REQUESTS="$ROOT/requests"
}
teardown() { teardown_manager; }

@test "Script update: versionless commands and aliases report current release without changing nodes" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    local generation digest
    generation=$(readlink -f "$ROOT/current")
    digest=$(sha256sum "$ROOT/current/nodes/n001.json")
    for command in 'update sh' 'U' 'update.sh' 'u sh latest' 'up sh'; do
        local -a args
        read -r -a args <<< "$command"
        run manager "${args[@]}"
        assert_status 0
        [[ $output == *"已是最新正式版 v$VERSION"* ]]
        [[ $(readlink -f "$ROOT/current") == "$generation" ]]
        [[ $(sha256sum "$ROOT/current/nodes/n001.json") == "$digest" ]]
    done
    [[ $(wc -l < "$BOOTSTRAP_REQUESTS") == 5 ]]
    [[ $(sort -u "$BOOTSTRAP_REQUESTS") == https://github.com/tktkl/Xray/releases/latest ]]
}

@test "Script update: latest resolver accepts only a fixed official release tag" {
    export BOOTSTRAP_LATEST_URL=https://github.com/tktkl/Xray/releases/tag/v10.20.30
    run latest_manager_version
    assert_status 0
    [[ $output == v10.20.30 ]]
    for destination in \
        'https://evil.test/tktkl/Xray/releases/tag/v1.2.3' \
        'http://github.com/tktkl/Xray/releases/tag/v1.2.3' \
        'https://github.com/another/Xray/releases/tag/v1.2.3' \
        'https://github.com/tktkl/Xray/releases/tag/main' \
        'https://github.com/tktkl/Xray/releases/tag/v1.2.3-rc1' \
        'https://github.com/tktkl/Xray/releases/tag/v1.2.3?source=latest' ''; do
        export BOOTSTRAP_LATEST_URL="$destination"
        run manager update sh
        [[ $status != 0 && $output == *最新正式版地址无效* ]]
    done
    [[ $(sort -u "$BOOTSTRAP_REQUESTS") == https://github.com/tktkl/Xray/releases/latest ]]
    [[ ! -e $ROOT/code-update.lock ]]
}

@test "Script update: latest lookup failure never falls back to branch or changes committed state" {
    manager a ss 23456 auto auto --address 127.0.0.1 >/dev/null
    local generation
    generation=$(readlink -f "$ROOT/current")
    export BOOTSTRAP_HTTP_FAIL=1
    run manager U
    [[ $status != 0 && $output == *无法查询最新正式版* ]]
    [[ $(cat "$BOOTSTRAP_REQUESTS") == https://github.com/tktkl/Xray/releases/latest ]]
    [[ $(readlink -f "$ROOT/current") == "$generation" && ! -e $ROOT/code-update.lock ]]
}

@test "Script update: explicit versions and checksums bypass latest and stay pinned" {
    export BOOTSTRAP_HTTP_FAIL=1
    run manager update sh v0.0.1
    [[ $status != 0 ]]
    [[ $(cat "$BOOTSTRAP_REQUESTS") == https://github.com/tktkl/Xray/releases/download/v0.0.1/SHA256SUMS ]]
    : > "$BOOTSTRAP_REQUESTS"
    local digest
    digest=$(printf '%064d' 0)
    run manager update.sh v0.0.2 --sha256 "$digest"
    [[ $status != 0 ]]
    [[ $(cat "$BOOTSTRAP_REQUESTS") == https://github.com/tktkl/Xray/releases/download/v0.0.2/xray-manager-v0.0.2.tar.gz ]]
    [[ ! -e $ROOT/code-update.lock ]]
}

@test "Script update: invalid versions and download overrides fail before network access" {
    for version in main ../v1.2.3 v1.2.3-rc1; do
        run manager U "$version"
        [[ $status != 0 && $output == *版本格式* ]]
    done
    run manager update sh --sha256 wrong
    [[ $status != 0 && $output == *SHA256* ]]
    run manager U --version v1.2.3
    [[ $status != 0 && $output == *用法* ]]
    run manager update sh --download-only /tmp/untrusted
    [[ $status != 0 && $output == *用法* ]]
    [[ ! -e $BOOTSTRAP_REQUESTS && ! -e $ROOT/code-update.lock ]]
}

@test "Script update: a resolved latest package still requires a matching SHA256" {
    export BOOTSTRAP_VERSION=v0.0.1 BOOTSTRAP_FIXTURE="$ROOT/release"
    mkdir "$BOOTSTRAP_FIXTURE"
    printf 'invalid archive\n' > "$BOOTSTRAP_FIXTURE/xray-manager-v0.0.1.tar.gz"
    printf '%064d  xray-manager-v0.0.1.tar.gz\n' 0 > "$BOOTSTRAP_FIXTURE/SHA256SUMS"
    run manager update sh
    [[ $status != 0 && $output == *SHA256* ]]
    [[ $(cat "$BOOTSTRAP_REQUESTS") == "$(printf '%s\n' \
        https://github.com/tktkl/Xray/releases/latest \
        https://github.com/tktkl/Xray/releases/download/v0.0.1/SHA256SUMS \
        https://github.com/tktkl/Xray/releases/download/v0.0.1/xray-manager-v0.0.1.tar.gz)" ]]
    [[ ! -e $ROOT/code-update.lock ]]
    [[ $(find "$ROOT" -maxdepth 1 -name 'script-update.*' | wc -l) == 0 ]]
}
