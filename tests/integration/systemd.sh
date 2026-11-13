#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(ps -p 1 -o comm=) == systemd ]]
cd /src
version="v$(awk -F= '/^VERSION=/{print $2;exit}' lib/common.sh)"
release_fixture=''
if [[ ${XRAY_TEST_RELEASE_BOOTSTRAP:-0} == 1 ]]; then
    # /tmp may be noexec in a systemd container; the curl fixture must execute.
    release_fixture=$(mktemp -d /var/tmp/xray-public-release.XXXXXX)
    mkdir -p "$release_fixture/bin"
    bash scripts/package-release.sh "$version" "$release_fixture/release"
    cp tests/fixtures/release-curl "$release_fixture/bin/curl"
    chmod +x "$release_fixture/bin/curl"
    PATH="$release_fixture/bin:$PATH" BOOTSTRAP_FIXTURE="$release_fixture/release" \
        bash bootstrap.sh --offline-cache /src/.cache
    [[ -s /usr/local/lib/xray-manager/code-current/bootstrap.sh ]]
else
    bash install.sh --offline-cache /src/.cache
fi
systemctl is-active --quiet xray-manager.service
before=$(systemctl show xray-manager.service --property=MainPID --value)
xray a socks 23451 integration integration-secret --address 127.0.0.1 >/dev/null
xray a socks 23452 integration integration-secret --address 127.0.0.1 >/dev/null
xray port n001 23453 >/dev/null
[[ $(systemctl show xray-manager.service --property=MainPID --value) == "$before" ]]
[[ $(stat -c %U /run/xray-manager/api.sock) == xray-manager ]]
runuser -u nobody -- head -c 1 /var/lib/xray-manager/current/nodes/n001.json 2>/dev/null && exit 1
systemctl stop xray-manager.service
xray port n001 23454 >/dev/null
! systemctl is-active --quiet xray-manager.service
systemctl start xray-manager.service
xray test
xray dns 11
[[ $(jq -r '.dns[0]' /var/lib/xray-manager/current/settings.json) == 1.1.1.1 ]]
xray log error
[[ $(jq -r .loglevel /var/lib/xray-manager/current/settings.json) == error ]]
systemctl is-active --quiet xray-manager.service
DOWNLOAD_CACHE=/src/.cache xray update core v26.11.9
systemctl is-active --quiet xray-manager.service
DOWNLOAD_CACHE=/src/.cache xray update dat
systemctl is-active --quiet xray-manager.service
if [[ -n $release_fixture ]]; then
    before=$(systemctl show xray-manager.service --property=MainPID --value)
    previous_code=$(readlink -f /usr/local/lib/xray-manager/code-current)
    PATH="$release_fixture/bin:$PATH" BOOTSTRAP_FIXTURE="$release_fixture/release" \
        xray update sh "$version"
    [[ $(systemctl show xray-manager.service --property=MainPID --value) == "$before" ]]
    [[ $(readlink -f /usr/local/lib/xray-manager/code-current) != "$previous_code" ]]
    printf 'PASS: public Release installation and verified atomic script update without GitHub credentials\n'
fi
# Simulate reboot with an uncommitted candidate installed on disk.
systemctl stop xray-manager.service xray-manager-recover.service
old=$(readlink -f /var/lib/xray-manager/current)
candidate=/var/lib/xray-manager/generations/recovery-fixture
cp -a "$old" "$candidate"
jq '.inbounds[0].port=24999' "$candidate/config.json" > "$candidate/config.next"
mv "$candidate/config.next" "$candidate/config.json"
jq -n --arg old "$old" --arg new "$candidate" '{old:$old,new:$new,phase:"prepared"}' > /var/lib/xray-manager/transaction.json
ln -sfn "$candidate" /var/lib/xray-manager/installed
systemctl start xray-manager.service
[[ $(readlink -f /var/lib/xray-manager/installed) == "$old" ]]
[[ ! -f /var/lib/xray-manager/transaction.json ]]
systemctl is-active --quiet xray-manager.service
systemctl enable --now xray-cert-deploy.timer
systemctl is-active --quiet xray-cert-deploy.timer
xray uninstall
! systemctl is-active --quiet xray-manager.service
[[ -f /var/lib/xray-manager/current/nodes/n001.json ]]
[[ ! -e /usr/local/bin/xray ]]
[[ -z $release_fixture ]] || rm -rf "$release_fixture"
printf 'PASS: real systemd installation, non-root API, stopped-service edits, persistence, timer and uninstall\n'
