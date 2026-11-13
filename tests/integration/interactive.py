#!/usr/bin/env python3
"""Exercise the actual terminal interface with a PTY and a real Xray validator."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import time


class Terminal:
    def __init__(self, *args):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvp(args[0], args)
        self.pending = b""
        self.transcript = b""
        self.closed = False

    def __enter__(self):
        return self

    def receive(self, timeout):
        if not select.select([self.fd], [], [], timeout)[0]:
            return True
        try:
            data = os.read(self.fd, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            return False
        self.pending += data
        self.transcript += data
        return bool(data)

    def expect(self, text, timeout=20):
        token = text.encode()
        deadline = time.monotonic() + timeout
        while token not in self.pending:
            if time.monotonic() >= deadline or not self.receive(0.1):
                raise AssertionError(f"Missing terminal text {text!r}:\n{self.transcript.decode(errors='replace')[-5000:]}")
        index = self.pending.index(token) + len(token)
        matched, self.pending = self.pending[:index], self.pending[index:]
        return matched.decode(errors="replace")

    def send(self, value):
        os.write(self.fd, value.encode() + b"\n")

    def choose(self, title, value):
        self.expect(title)
        options = self.expect("请输入序号")
        zero_label = "退出" if title == "Xray 管理菜单" else "上一步"
        assert f"0) {zero_label}" in options, options
        self.send(value)
        return options

    def answer(self, title, value):
        self.expect(title)
        self.send(value)

    def finish(self, status=0):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            self.receive(0.05)
            pid, result = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.closed = True
                actual = os.waitstatus_to_exitcode(result)
                assert actual == status, (actual, self.transcript.decode(errors="replace")[-5000:])
                return
        raise AssertionError("Interactive command did not exit")

    def __exit__(self, *_):
        if not self.closed:
            os.kill(self.pid, signal.SIGTERM)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


ROOT = Path(os.environ["XRAY_MANAGER_ROOT"])
BIN = "/src/bin/xray"


def node(node_id):
    return json.loads((ROOT / "current/nodes" / f"{node_id}.json").read_text())


def run(*args):
    return subprocess.run([BIN, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)


with Terminal(BIN) as terminal:
    terminal.choose("Xray 管理菜单", "1")
    options = terminal.choose("选择协议", "99")
    for label in ("VLESS-REALITY", "Shadowsocks", "VMess WS", "VMess gRPC", "Hysteria2", "SOCKS5", "14)"):
        assert label in options, label
    terminal.expect("无效选择")
    assert not list((ROOT / "current/nodes").glob("*.json"))
    terminal.expect("请输入序号")
    terminal.send("1")
    terminal.answer("公网端口", "24443")
    terminal.choose("选择 REALITY SNI", "2")
    terminal.expect("已添加 n001")
    assert node("n001")["sni"] == "apps.mzstatic.com"

    terminal.choose("Xray 管理菜单", "1")
    terminal.choose("选择协议", "2")
    terminal.answer("公网端口", "24444")
    terminal.choose("选择 Shadowsocks 加密方式", "2")
    terminal.expect("已添加 n002")
    assert node("n002")["credentials"]["method"] == "2022-blake3-aes-256-gcm"

    # The first modification selects a node and then an option by number.
    terminal.choose("Xray 管理菜单", "2")
    terminal.choose("选择节点", "1")
    options = terminal.choose("修改节点 n001", "1")
    assert "修改 UUID" in options and "修改 REALITY SNI" in options
    assert "修改密码" not in options and "修改 SS 加密方式" not in options
    terminal.answer("新的公网端口", "24445")
    terminal.expect("ID: n001")
    assert node("n001")["endpoint"]["port"] == 24445
    assert node("n002")["endpoint"]["port"] == 24444

    terminal.choose("Xray 管理菜单", "7")
    terminal.choose("选择节点", "1")
    terminal.choose("设置节点出口", "2")
    terminal.answer("请粘贴完整的出口分享链接", "ss://aes-128-gcm:fixture-password@127.0.0.1:12345")
    terminal.expect("ID: n001")
    assert node("n001")["outbound"]["protocol"] == "shadowsocks"
    assert node("n002")["outbound"]["protocol"] == "freedom"

    # Cancelled selectors, submenus and invalid numbers must not commit anything.
    before = (ROOT / "current").resolve()
    terminal.choose("Xray 管理菜单", "4")
    terminal.choose("选择节点", "0")
    terminal.expect("已返回上一步")
    assert (ROOT / "current").resolve() == before
    for number, title in (("1", "选择协议"), ("2", "选择节点"), ("8", "选择导出方式"),
                          ("9", "服务管理"), ("10", "证书与域名管理"), ("13", "选择更新组件")):
        terminal.choose("Xray 管理菜单", number)
        terminal.choose(title, "0")
        terminal.expect("已返回上一步")
        assert (ROOT / "current").resolve() == before

    # Back returns to the immediate parent instead of discarding the whole flow.
    terminal.choose("Xray 管理菜单", "2")
    terminal.choose("选择节点", "1")
    terminal.choose("修改节点 n001", "2")
    terminal.choose("选择协议", "0")
    terminal.choose("修改节点 n001", "1")
    terminal.answer("新的公网端口", "0")
    terminal.choose("修改节点 n001", "0")
    terminal.choose("选择节点", "0")
    assert (ROOT / "current").resolve() == before

    terminal.choose("Xray 管理菜单", "7")
    terminal.choose("选择节点", "2")
    terminal.choose("设置节点出口", "2")
    terminal.answer("请粘贴完整的出口分享链接", "0")
    terminal.choose("设置节点出口", "0")
    terminal.choose("选择节点", "0")
    assert node("n002")["outbound"]["protocol"] == "freedom"

    terminal.choose("Xray 管理菜单", "12")
    terminal.choose("日志管理", "3")
    terminal.choose("全局日志级别", "0")
    terminal.choose("日志管理", "0")

    terminal.choose("Xray 管理菜单", "8")
    terminal.choose("选择导出方式", "2")
    terminal.choose("选择节点", "0")
    terminal.choose("选择导出方式", "0")

    terminal.choose("Xray 管理菜单", "8")
    terminal.choose("选择导出方式", "4")
    terminal.choose("选择节点", "0")
    terminal.choose("选择导出方式", "0")

    terminal.choose("Xray 管理菜单", "13")
    terminal.choose("选择更新组件", "2")
    terminal.answer("已发布的脚本版本", "0")
    terminal.choose("选择更新组件", "0")

    terminal.choose("Xray 管理菜单", "10")
    terminal.choose("证书与域名管理", "3")
    terminal.answer("域名", "0")
    terminal.choose("证书与域名管理", "2")
    terminal.answer("ACME 联系邮箱", "0")
    terminal.choose("证书与域名管理", "2")
    terminal.answer("ACME 联系邮箱", "audit@example.test")
    terminal.answer("Cloudflare API Token", "0")
    terminal.choose("证书与域名管理", "0")
    assert not (ROOT / "cloudflare.ini").exists()
    assert not (ROOT / "acme.json").exists()

    terminal.choose("Xray 管理菜单", "11")
    terminal.choose("选择全局 DNS", "7")
    terminal.answer("DNS 地址", "0")
    terminal.choose("选择全局 DNS", "0")

    terminal.choose("Xray 管理菜单", "14")
    terminal.choose("配置检查与恢复", "3")
    terminal.choose("选择节点", "0")
    terminal.choose("配置检查与恢复", "0")

    terminal.choose("Xray 管理菜单", "1")
    terminal.choose("选择协议", "1")
    terminal.answer("公网端口", "0")
    terminal.choose("选择协议", "2")
    terminal.answer("公网端口", "24449")
    terminal.choose("选择 Shadowsocks 加密方式", "0")
    terminal.choose("选择协议", "1")
    terminal.answer("公网端口", "24449")
    terminal.choose("选择 REALITY SNI", "4")
    terminal.answer("请输入 SNI 域名", "0")
    terminal.choose("选择 REALITY SNI", "0")
    terminal.choose("选择协议", "0")
    assert (ROOT / "current").resolve() == before

    terminal.choose("Xray 管理菜单", "2")
    terminal.choose("选择节点", "1")
    terminal.choose("修改节点 n001", "1")
    terminal.answer("新的公网端口", "65536")
    terminal.expect("无效端口")
    terminal.expect("操作未完成")
    assert (ROOT / "current").resolve() == before

    terminal.choose("Xray 管理菜单", "11")
    terminal.choose("选择全局 DNS", "5")
    terminal.expect("DNS 修改是全局操作")
    terminal.expect("Xray 管理菜单")
    settings = json.loads((ROOT / "current/settings.json").read_text())
    assert settings["dns"] == ["https+local://cloudflare-dns.com/dns-query"]
    terminal.expect("请输入序号")
    terminal.send("12")
    terminal.choose("日志管理", "3")
    terminal.choose("全局日志级别", "4")
    terminal.expect("日志设置是全局操作")
    terminal.expect("Xray 管理菜单")
    assert json.loads((ROOT / "current/settings.json").read_text())["loglevel"] == "error"
    terminal.expect("请输入序号")
    terminal.send("14")
    terminal.choose("配置检查与恢复", "1")
    terminal.choose("Xray 管理菜单", "0")
    terminal.finish()

# Regression: `c n001` used to leave the selector in $1 and treat it as a value.
with Terminal(BIN, "c", "n001") as terminal:
    terminal.choose("修改节点 n001", "1")
    terminal.answer("新的公网端口", "24446")
    terminal.finish()
assert node("n001")["endpoint"]["port"] == 24446

with Terminal(BIN, "c", "n002") as terminal:
    options = terminal.choose("修改节点 n002", "6")
    assert "修改密码" in options and "修改 SS 加密方式" in options
    assert "修改 UUID" not in options and "REALITY" not in options
    terminal.choose("选择 Shadowsocks 加密方式", "4")
    terminal.finish()
assert node("n002")["credentials"]["method"] == "aes-128-gcm"
assert json.loads(run("client", "n001", "legacy").stdout)["outbounds"][0]["streamSettings"]["realitySettings"]["publicKey"]

with Terminal(BIN, "sni", "n001") as terminal:
    terminal.choose("选择 REALITY SNI", "3")
    terminal.finish()
assert node("n001")["sni"] == "xp.apple.com"

old_outbound = node("n001")["outbound"]
with Terminal(BIN, "new", "n001") as terminal:
    terminal.choose("选择协议", "2")
    terminal.answer("公网端口", "")
    terminal.choose("选择 Shadowsocks 加密方式", "1")
    terminal.finish()
assert node("n001")["protocol"] == "Shadowsocks"
assert node("n001")["endpoint"]["port"] == 24446
assert node("n001")["outbound"] == old_outbound

# Leading-zero node choices are decimal, and explicit CLI/auto remains unattended.
with Terminal(BIN, "c") as terminal:
    terminal.choose("选择节点", "02")
    terminal.choose("修改节点 n002", "1")
    terminal.answer("新的公网端口", "24447")
    terminal.finish()
assert node("n002")["endpoint"]["port"] == 24447
run("port", "n002", "24448")
run("passwd", "n002", "auto")
run("ob", "n001", "direct")
assert node("n002")["endpoint"]["port"] == 24448
assert node("n001")["outbound"]["protocol"] == "freedom"
before = (ROOT / "current").resolve()
assert "用法" in run().stdout
assert (ROOT / "current").resolve() == before

# TLS wizards collect the public port/path; no certificate is issued while collecting.
command = ('set -Eeuo pipefail; source /src/lib/common.sh; source /src/lib/protocol.sh; '
           'build_node_interactive vws "{}"; printf "%s" "$NODE" > "$XRAY_MANAGER_ROOT/preview.json"')
with Terminal("bash", "-c", command) as terminal:
    terminal.answer("证书域名", "example.test")
    terminal.answer("路径／gRPC 服务名", "/interactive-ws")
    terminal.answer("公网 TCP 端口", "8443")
    terminal.finish()
preview = json.loads((ROOT / "preview.json").read_text())
assert preview["endpoint"]["port"] == 8443
assert preview["endpoint"]["path"] == "/interactive-ws"
assert preview["security"] == "nginx"

# Additional protocol kinds show applicable modifications and allow cancellation.
for args, required, excluded in (
        ("socks 24501", ("修改密码", "SOCKS 用户名"), ("修改 UUID", "修改路径", "修改证书域名")),
        ("door 24501 example.test 443", ("转发目标地址", "转发目标端口"), ("修改密码", "修改 UUID")),
        ("hy2 24501 auto --domain example.test", ("修改密码", "修改证书域名"), ("修改路径", "伪装网站")),
        ("tgrpc example.test auto /test", ("修改密码", "修改证书域名", "修改路径", "伪装网站"), ("修改 UUID", "REALITY SNI")),
        ("kcp 24501", ("修改 UUID", "mKCP seed"), ("修改密码", "修改证书域名"))):
    protocol, parameters = args.split(" ", 1)
    command = ('set -Eeuo pipefail; source /src/lib/common.sh; source /src/lib/protocol.sh; source /src/lib/commands.sh; '
               f'build_node {protocol} "{{}}" {parameters} --address 127.0.0.1; select_change_option "$NODE"')
    with Terminal("bash", "-c", command) as terminal:
        options = terminal.choose("修改节点", "0")
        assert all(label in options for label in required), options
        assert all(label not in options for label in excluded), options
        terminal.finish(125)
assert (ROOT / "current").resolve() == before

# Every advertised protocol is reachable numerically, with no menu text on stdout.
for number, alias in enumerate(("reality", "ss", "tcp", "kcp", "ws", "grpc", "vws", "vgrpc",
                                 "xhttp", "tws", "tgrpc", "hy2", "socks", "door"), 1):
    command = 'source /src/lib/common.sh; source /src/lib/protocol.sh; v=$(select_protocol) || exit; printf "RESULT=<%s>\\n" "$v"'
    with Terminal("bash", "-c", command) as terminal:
        terminal.choose("选择协议", str(number))
        terminal.expect(f"RESULT=<{alias}>")
        terminal.finish()

command = 'source /src/lib/common.sh; source /src/lib/commands.sh; v=$(select_website) || exit; printf "RESULT=<%s>\\n" "$v"'
with Terminal("bash", "-c", command) as terminal:
    terminal.choose("选择域名共享的伪装网站", "2")
    terminal.answer("伪装网站域名", "www.example.org")
    terminal.expect("RESULT=<www.example.org>")
    terminal.finish()

with Terminal(BIN, "a") as terminal:
    terminal.expect("请输入序号")
    os.write(terminal.fd, b"\x04")
    terminal.finish(130)
assert (ROOT / "current").resolve() == before

# Even a single-node interactive selector offers Back instead of acting immediately.
run("d", "n002")
before = (ROOT / "current").resolve()
with Terminal(BIN) as terminal:
    terminal.choose("Xray 管理菜单", "4")
    options = terminal.choose("选择节点", "0")
    assert "n001" in options
    terminal.choose("Xray 管理菜单", "0")
    terminal.finish()
with Terminal(BIN) as terminal:
    terminal.expect("请输入序号")
    os.write(terminal.fd, b"\x04")
    terminal.finish()
assert (ROOT / "current").resolve() == before
print("PASS: numbered menus, immediate-parent Back, explicit Exit, single-node Back, EOF and CLI compatibility")
