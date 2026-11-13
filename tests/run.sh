#!/usr/bin/env bash
set -Eeuo pipefail
cd /src
if [[ ! -x /opt/xray-core/xray ]]; then
    arch=$(uname -m)
    [[ $arch != aarch64 ]] || arch=arm64-v8a
    [[ $arch != x86_64 ]] || arch=64
    unzip -qo ".cache/Xray-linux-$arch.zip" -d /opt/xray-core
    cp .cache/{geoip,geosite}.dat /opt/xray-core/
fi
case $(uname -m) in aarch64) client_arch=arm64;; x86_64) client_arch=amd64;; *) exit 1;; esac
while IFS= read -r client_version; do
    client_cache=".cache/client-$client_version-$client_arch.zip"
    client_digest=$(jq -r --arg v "$client_version" --arg a "$client_arch" '.[$v][$a].sha256' tests/client-releases.json)
    printf '%s  %s\n' "$client_digest" "$client_cache" | sha256sum -c - >/dev/null
    mkdir -p "/opt/xray-clients/$client_version"
    unzip -qo "$client_cache" -d "/opt/xray-clients/$client_version"
done < <(jq -r 'keys[]' tests/client-releases.json)
shellcheck -S warning bin/xray install.sh bootstrap.sh scripts/*.sh lib/*.sh tests/*.sh tests/integration/*.sh tests/fixtures/systemctl tests/fixtures/core-api tests/fixtures/release-curl
bats tests/unit.bats tests/bootstrap.bats
bash -c 'set -Eeuo pipefail; source /src/tests/helper.bash; setup_manager; trap teardown_manager EXIT; python3 /src/tests/integration/interactive.py'
bash tests/integration/core.sh
bash tests/integration/tls.sh
