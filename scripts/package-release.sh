#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VERSION=$(awk -F= '/^VERSION=/{print $2;exit}' "$HERE/lib/common.sh")
TAG=${1:-v$VERSION}
[[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $TAG == "v$VERSION" ]] || { printf '发布标签必须与 lib/common.sh 的版本 v%s 一致。\n' "$VERSION" >&2; exit 1; }
OUTPUT=${2:-$HERE/dist}
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd -P)
ASSET="xray-manager-$TAG.tar.gz"
tar -czf "$OUTPUT/$ASSET" -C "$HERE" bin lib jq config systemd install.sh bootstrap.sh README.md docs examples
sed "s/^DEFAULT_VERSION=.*/DEFAULT_VERSION='$TAG'/" "$HERE/bootstrap.sh" > "$OUTPUT/install.sh"
chmod 755 "$OUTPUT/install.sh"
{
    for file in "$ASSET" install.sh; do
        digest=$(openssl dgst -sha256 "$OUTPUT/$file" | awk '{print $NF}')
        printf '%s  %s\n' "$digest" "$file"
    done
} > "$OUTPUT/SHA256SUMS"
printf '已生成 %s、install.sh 和 SHA256SUMS：%s\n' "$ASSET" "$OUTPUT"
