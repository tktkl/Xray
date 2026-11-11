#!/usr/bin/env bats
setup() {
    TEST_ROOT=$(mktemp -d /tmp/xray-bootstrap-test.XXXXXX)
    export BOOTSTRAP_FIXTURE="$TEST_ROOT/release"
    export BOOTSTRAP_RECORD="$TEST_ROOT/invoked"
    export TMPDIR="$TEST_ROOT/tmp"
    mkdir -p "$BOOTSTRAP_FIXTURE" "$TEST_ROOT/bin" "$TMPDIR"
    cp /src/tests/fixtures/release-curl "$TEST_ROOT/bin/curl"
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
    PACKAGE="$TEST_ROOT/package"
    mkdir -p "$PACKAGE/"{bin,lib,jq,config,systemd}
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$BOOTSTRAP_RECORD"\n' > "$PACKAGE/bin/xray"
    for file in lib/common.sh lib/install.sh jq/render.jq config/releases.json systemd/xray-manager.service; do printf '# fixture\n' > "$PACKAGE/$file"; done
    make_archive
}
teardown() { rm -rf "$TEST_ROOT"; }
make_archive() {
    tar -czf "$BOOTSTRAP_FIXTURE/xray-manager-v0.1.0.tar.gz" -C "$PACKAGE" bin lib jq config systemd
    (cd "$BOOTSTRAP_FIXTURE" && sha256sum xray-manager-v0.1.0.tar.gz > SHA256SUMS)
}
bootstrap() { bash /src/bootstrap.sh "$@"; }

@test "Public Release: default install needs no credentials and executes only a verified bundle" {
    run bootstrap --offline-cache "$TEST_ROOT"
    [[ $status == 0 ]]
    [[ $(cat "$BOOTSTRAP_RECORD") == "$(printf 'install\n--offline-cache\n%s' "$TEST_ROOT")" ]]
    [[ $(find "$TMPDIR" -mindepth 1 | wc -l) == 0 ]]
    [[ $output != *github_pat* ]]
}
@test "Public Release: wrong checksum never executes code" {
    printf '%064d  xray-manager-v0.1.0.tar.gz\n' 0 > "$BOOTSTRAP_FIXTURE/SHA256SUMS"
    run bootstrap
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
    [[ $(find "$TMPDIR" -mindepth 1 | wc -l) == 0 ]]
}
@test "Public Release: duplicate checksum is rejected" {
    cat "$BOOTSTRAP_FIXTURE/SHA256SUMS" >> "$TEST_ROOT/duplicate"
    cat "$TEST_ROOT/duplicate" >> "$BOOTSTRAP_FIXTURE/SHA256SUMS"
    run bootstrap
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
}
@test "Public Release: network failure or missing version stops before execution" {
    export BOOTSTRAP_HTTP_FAIL=1
    run bootstrap
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
    [[ $output != *github_pat* ]]
}
@test "Public Release: archive path traversal is rejected even with matching checksum" {
    tar -czf "$BOOTSTRAP_FIXTURE/xray-manager-v0.1.0.tar.gz" --transform='s|bin/xray|../outside|' -C "$PACKAGE" bin lib jq config systemd
    (cd "$BOOTSTRAP_FIXTURE" && sha256sum xray-manager-v0.1.0.tar.gz > SHA256SUMS)
    run bootstrap
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
    [[ ! -e $TEST_ROOT/outside ]]
}
@test "Public Release: archive symlinks are rejected even with matching checksum" {
    ln -s /etc/passwd "$PACKAGE/lib/link"
    make_archive
    run bootstrap
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
}
@test "Public Release: branch names and traversal versions are rejected" {
    run bootstrap --version ../main
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
    run bootstrap --version main
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
}
@test "Public Release: download-only validates without running the installer" {
    run bootstrap --download-only "$TEST_ROOT/unpacked"
    [[ $status == 0 && -f $TEST_ROOT/unpacked/bin/xray && ! -e $BOOTSTRAP_RECORD ]]
}
@test "Public Release: legacy credential options are rejected" {
    run bootstrap --github-token-file /missing
    [[ $status != 0 && ! -e $BOOTSTRAP_RECORD ]]
}
@test "Public Release: explicit checksum works without a checksum attachment" {
    digest=$(awk '{print $1}' "$BOOTSTRAP_FIXTURE/SHA256SUMS")
    rm "$BOOTSTRAP_FIXTURE/SHA256SUMS"
    run bootstrap --sha256 "$digest"
    [[ $status == 0 && -f $BOOTSTRAP_RECORD ]]
}
