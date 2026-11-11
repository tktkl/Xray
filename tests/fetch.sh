#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
manifest=config/releases.json
for arch in "${@:-arm64}"; do
    asset=$(jq -r --arg a "$arch" '.core["v26.11.9"][$a].asset' "$manifest")
    digest=$(jq -r --arg a "$arch" '.core["v26.11.9"][$a].sha256' "$manifest")
    if [[ ! -e .cache/$asset ]] || [[ $(openssl dgst -sha256 ".cache/$asset" | awk '{print $NF}') != "$digest" ]]; then
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 900 --proto '=https' "https://github.com/XTLS/Xray-core/releases/download/v26.11.9/$asset" -o ".cache/$asset"
    fi
    [[ $(openssl dgst -sha256 ".cache/$asset" | awk '{print $NF}') == "$digest" ]]
done
version=$(jq -r '.data.version' "$manifest")
for name in geoip.dat geosite.dat; do
    digest=$(jq -r --arg n "$name" '.data[$n]' "$manifest")
    if [[ ! -e .cache/$name ]] || [[ $(openssl dgst -sha256 ".cache/$name" | awk '{print $NF}') != "$digest" ]]; then
        curl --fail --silent --show-error --location --retry 3 --max-time 900 --proto '=https' "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$version/$name" -o ".cache/$name"
    fi
    [[ $(openssl dgst -sha256 ".cache/$name" | awk '{print $NF}') == "$digest" ]]
done
