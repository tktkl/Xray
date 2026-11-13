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
shellcheck -S warning bin/xray install.sh bootstrap.sh scripts/*.sh lib/*.sh tests/*.sh tests/integration/*.sh tests/fixtures/systemctl tests/fixtures/core-api tests/fixtures/release-curl tests/fixtures/core-curl tests/fixtures/core-systemctl
bats tests/unit.bats tests/bootstrap.bats tests/update.bats tests/core-update.bats
bash -c 'set -Eeuo pipefail; source /src/tests/helper.bash; setup_manager; trap teardown_manager EXIT; python3 /src/tests/integration/interactive.py'
bash tests/integration/core.sh
bash tests/integration/tls.sh
