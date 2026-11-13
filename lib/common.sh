#!/usr/bin/env bash
VERSION=0.1.4
MANAGER_ENTRYPOINT=${XRAY_MANAGER_ENTRYPOINT:-/usr/local/lib/xray-manager/bin/xray}
ROOT=${XRAY_MANAGER_ROOT:-/var/lib/xray-manager}
CORE=${XRAY_CORE_BIN:-/usr/local/lib/xray-manager/core/xray}
ASSETS=${XRAY_ASSET_DIR:-/usr/local/lib/xray-manager/core}
SOCKET=${XRAY_API_SOCKET:-/run/xray-manager/api.sock}
SERVICE_USER=${XRAY_SERVICE_USER:-xray-manager}
NGINX_MAIN=${XRAY_NGINX_CONF:-/etc/nginx/nginx.conf}
NGINX_LOADER=${XRAY_NGINX_LOADER:-/etc/nginx/conf.d/xray-manager.conf}
STATE=
LOCKED=0

die() { printf '错误：%s\n' "$*" >&2; return 1; }
note() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null || die "缺少依赖：$1"; }
require_root() { (( EUID == 0 )) || die '此操作需要 root。'; }
random_hex() { openssl rand -hex "${1:-16}"; }
uuid() { "$CORE" uuid; }
nonempty() { [[ -n $1 && $1 != *[[:cntrl:]]* ]] || die '参数不能为空或包含控制字符。'; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_domain() {
    local d=$1 label
    [[ ${#d} -le 253 && $d == *.* && $d != *..* && $d != *[!a-zA-Z0-9.-]* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$d"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
    [[ $d != *. ]]
}
valid_address() {
    nonempty "$1" || return
    [[ $1 =~ ^[a-zA-Z0-9:.%-]+$ && $1 != -* && $1 != *%* ]] || die '地址含有非法字符。'
}
valid_path() { [[ $1 =~ ^/[a-zA-Z0-9_./~-]*$ && $1 != *..* && $1 != *//* ]]; }
prompt() {
    local message=$1 default=${2:-} answer
    [[ -t 0 ]] || { [[ -n $default ]] && { printf '%s' "$default"; return; }; die "非交互模式缺少参数：$message"; return; }
    read -r -p "$message${default:+ [$default]}: " answer || return 130
    printf '%s' "${answer:-$default}"
}
# Menus write their presentation to stderr; stdout contains only the selected value.
menu_select() {
    local zero_label=上一步
    if [[ ${1:-} == --exit ]]; then zero_label=退出; shift; fi
    local title=$1 default=$2 answer key default_number='' index i
    shift 2
    local -a values=() labels=()
    while (($#>=2)); do
        values+=("$1"); labels+=("$2"); shift 2
    done
    ((${#values[@]})) || { die '菜单没有可用选项。'; return; }
    for i in "${!values[@]}"; do
        [[ ${values[$i]} != "$default" ]] || default_number=$((i+1))
    done
    if [[ ! -t 0 ]]; then
        [[ -n $default_number ]] || { die "非交互模式请指定参数：$title"; return; }
        printf '%s' "$default"; return
    fi
    printf '\n%s\n' "$title" >&2
    for i in "${!values[@]}"; do printf '%2d) %s\n' "$((i+1))" "${labels[$i]}" >&2; done
    printf ' 0) %s\n' "$zero_label" >&2
    while :; do
        answer=$(prompt '请输入序号' "$default_number") || return
        if [[ $answer == 0 ]]; then
            if [[ $zero_label == 退出 ]]; then note '已退出。'; else note '已返回上一步。'; fi
            return 125
        fi
        if [[ $answer =~ ^[0-9]{1,6}$ ]] && ((10#$answer>=1 && 10#$answer<=${#values[@]})); then
            index=$((10#$answer-1)); printf '%s' "${values[$index]}"; return
        fi
        for key in "${values[@]}"; do
            if [[ $answer == "$key" ]]; then printf '%s' "$key"; return; fi
        done
        note "无效选择，请输入 1–${#values[@]}，或输入 0 $zero_label。"
    done
}
prompt_step() {
    local answer
    answer=$(prompt "$1，0 上一步" "${2:-}") || return
    [[ $answer != 0 ]] || return 125
    printf '%s' "$answer"
}
auto_value() { [[ ${1:-} == auto ]] && printf '' || printf '%s' "${1:-}"; }
sync_path() { sync -f "$1"; }
atomic_file() {
    local dest=$1 tmp
    tmp=$(mktemp "${dest}.tmp.XXXXXX") || return
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || return
    sync_path "$tmp" || return
    mv -f -- "$tmp" "$dest" || return
    sync_path "$(dirname -- "$dest")"
}
atomic_link() {
    local target=$1 dest=$2 tmp
    tmp="${2}.tmp.$(random_hex 6)"
    ln -s -- "$target" "$tmp" || return
    mv -Tf -- "$tmp" "$dest" || return
    sync_path "$(dirname -- "$dest")"
}
as_service() {
    if [[ $(id -un) == "$SERVICE_USER" ]]; then
        env XRAY_LOCATION_ASSET="$ASSETS" "$@"
    else
        runuser -u "$SERVICE_USER" -- env XRAY_LOCATION_ASSET="$ASSETS" "$@"
    fi
}
service_active() { systemctl is-active --quiet "$1"; }
process_identity() { systemctl show xray-manager.service --property=MainPID --property=ExecMainStartTimestampMonotonic --value | tr '\n' ':'; }
json_redact() {
    jq 'walk(if type=="object" then with_entries(if (.key|test("password|private.?key|public.?key|short.?id|^id$|^auth$|^user$|^pass$|username|^seed$";"i")) then .value="<redacted>" else . end) else . end)'
}
fault() {
    # Fault injection is restricted to an explicitly isolated test root.
    if [[ ${XRAY_TESTING:-0} == 1 && $ROOT == /tmp/* && ${XRAY_TEST_FAULT:-} == "$1" ]]; then
        kill -KILL "$$"
    fi
}
