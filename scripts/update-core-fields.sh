#!/usr/bin/env bash
set -Eeuo pipefail
MANAGER_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$MANAGER_HOME/lib/common.sh"
source "$MANAGER_HOME/lib/core-update.sh"
[[ $# == 2 && -d $1/infra/conf && $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf '用法：bash scripts/update-core-fields.sh CORE_SOURCE_DIR v版本\n' >&2; exit 1;
}
fields=$(core_source_fields "$1/infra/conf")
jq -n --arg version "$2" --argjson fields "$fields" '{version:$version,fields:$fields}'
