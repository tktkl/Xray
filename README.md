# Xray 管理脚本

一个 Xray 进程管理多个独立节点。相同协议可以反复添加到不同端口，每个节点的协议、端口、凭据和出口都可以单独修改。

支持 **Debian 12／13、Ubuntu 22.04／24.04，amd64／arm64**，需要 systemd。

## 安装

在服务器上按自己的用户身份执行。第一行安装下载工具，已有 `curl` 和 CA 证书时可以跳过。

### root 用户

```bash
apt-get update && apt-get install -y curl ca-certificates
curl -fL --proto '=https' --proto-redir '=https' -o xray-install.sh https://github.com/tktkl/Xray/releases/download/v0.1.1/install.sh && bash xray-install.sh
```

安装后直接运行 `xray`。

### 普通用户（有 sudo 权限）

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates
curl -fL --proto '=https' --proto-redir '=https' -o xray-install.sh https://github.com/tktkl/Xray/releases/download/v0.1.1/install.sh && sudo bash xray-install.sh
```

安装后运行 `sudo xray`。普通用户没有 sudo 权限时，先执行 `su -` 切换到 root，再按 root 用户的步骤安装；安装和管理均需要 root 权限。

安装完成后没有默认节点，需要自行添加。已有其他 Xray 安装时，脚本会停止，避免覆盖。脚本不自动修改防火墙，请自行在云防火墙及系统防火墙放行节点使用的 TCP／UDP 端口。

**下文命令以 root 用户为例；普通用户请在每条 `xray` 命令前加 `sudo`。**

## 开始使用

打开交互菜单或查看完整帮助：

```bash
xray
xray help
```

菜单中的协议和操作均按序号选择，输入 `0` 取消并返回主菜单；输错序号会提示重新选择。例如添加 REALITY：选择 `1` 添加节点 → 选择 `1` VLESS-REALITY → 输入端口 → 选择 SNI。完成后自动回到主菜单，可以继续添加或修改其他节点。

添加两个 VLESS-REALITY 节点，然后查看、导出：

```bash
xray a reality 24443
xray a reality 24444
xray list
xray url n001
```

全新安装时，这两个节点分别为 `n001`、`n002`，各自生成凭据。后续操作请使用添加结果或 `xray list` 显示的实际 ID，也可以使用节点名称。

REALITY 不需要自己的域名、证书或 Cloudflare Token。默认从 `apps.mzstatic.com`、`xp.apple.com` 中选择通过检测的 SNI；也可以指定：

```bash
xray a reality 24445 auto apps.mzstatic.com
```

`auto` 表示自动生成对应参数，上例中生成 UUID。若服务器位于 NAT 后，添加时通过 `--address` 指定客户端能够连接的公网地址：

```bash
xray a reality 24446 --name mobile --address 203.0.113.10
```

请将 `203.0.113.10` 换成实际公网 IP。

## 添加其他协议

按需选择，端口可以自行替换：

| 协议 | 添加示例 |
|---|---|
| Shadowsocks／SS2022 | `xray a ss 24447` |
| SOCKS5（自动生成用户名和密码） | `xray a socks 24448` |
| VMess TCP | `xray a tcp 24449` |
| VMess mKCP | `xray a kcp 24450` |
| 固定目标端口转发 | `xray a door 24451 remote.example.com 443` |

这些协议无需配置证书。需要域名和证书的协议见下方“域名、TLS 与伪装网站”。

## 查看与导出节点

| 命令 | 用途 |
|---|---|
| `xray list` | 列出所有节点的 ID、名称、协议、端口和出口 |
| `xray i n001` | 查看一个节点的连接信息和分享链接 |
| `xray url n001` | 输出分享链接，复制到客户端导入 |
| `xray qr n001` | 在终端显示二维码，供客户端扫描 |
| `xray client n001` | 输出 Xray 客户端 JSON 配置 |

端口转发等不支持分享链接的类型会给出提示。

## 修改一个节点

```bash
xray c n001
```

按提示选择修改项，也可以直接执行：

修改菜单只显示当前节点适用的选项。选择“切换入口协议”后，同样按序号选择新协议；选择端口、密码等修改项后，再输入新值或用 `auto` 自动生成。

| 命令 | 用途 |
|---|---|
| `xray port n001 24452` | 修改该节点的公网端口 |
| `xray address n001 203.0.113.10` | 修改分享链接使用的公网地址 |
| `xray id n001 auto` | 重新生成 UUID，适用于 VLESS／VMess |
| `xray key n001 auto` | 重新生成 REALITY 密钥 |
| `xray sni n001 xp.apple.com` | 修改 REALITY SNI |
| `xray passwd n001 auto` | 重新生成密码，适用于 SS／Trojan／SOCKS／Hysteria2 |
| `xray method n001 chacha20-ietf-poly1305` | 修改 SS 加密方式，同时生成新密码 |
| `xray new n001 ss` | 将入口协议改为 SS，保留该节点的端口和出口 |

按当前节点协议选择适用的命令。`id` 修改的是连接凭据 UUID；节点 ID `n001` 始终不变。修改连接参数后，重新执行 `xray url n001` 并更新客户端。

普通节点修改允许当前节点短暂断连，其他节点继续运行。

## 设置节点出口

新节点默认由本机直连。交互设置一个节点的出口：

```bash
xray ob n001
```

按提示粘贴 SS、VLESS、VMess、Trojan、SOCKS5 或 HTTP 上游链接。也可以直接传入完整分享链接；下面的 `ss://…` 需要替换为真实链接，并保留引号：

```bash
xray ob n001 'ss://…'
```

改回本机直连：

```bash
xray ob n001 direct
```

`xray c n001 outbound direct` 是等价写法。每个节点独立保存出口；修改或删除一个节点不会改动其他节点的出口。代理出口不可用时不会自动改走直连。HTTP 出口仅支持 TCP。

默认阻止 BT、中国 IP 和内网业务目标；域名解析默认使用服务器 DNS。

## 删除节点

```bash
xray d n001
```

一次删除多个指定节点：

```bash
xray dd n002 n003
```

删除节点不会自动删除共享的域名网站或证书。

## 域名、TLS 与伪装网站

仅添加 WS／gRPC／XHTTP＋TLS 或 Hysteria2 时需要这一节。请准备自己的域名，并自行配置 A／AAAA 指向服务器。

### 配置 Cloudflare Token

为对应 Zone 创建具有 DNS 编辑权限的 Cloudflare API Token，然后执行：

```bash
xray cert setup --email admin@example.com
```

将邮箱换成自己的邮箱，按提示输入 Token，输入过程不显示内容。所有受管证书共用这一份 Token。脚本通过 Certbot 自动签发、续期和部署证书，仅管理验证 TXT，不修改 A／AAAA 或橙云状态。

### 添加 TLS 节点

以下将 `node.example.com` 换成自己的域名。示例为同域名、不同路径的三个节点，默认公网端口均为 TCP 443：

```bash
xray a vws node.example.com auto /node-one
xray a vgrpc node.example.com auto /node-two
xray a xhttp node.example.com auto /node-three
```

| 协议别名 | 协议 |
|---|---|
| `ws`／`grpc` | VMess WS／gRPC＋TLS |
| `vws`／`vgrpc`／`xhttp` | VLESS WS／gRPC／XHTTP＋TLS |
| `tws`／`tgrpc` | Trojan WS／gRPC＋TLS |

这些节点自动使用 Nginx，同一域名共用一个站点文件；节点路径必须互不冲突。`xray port 节点ID 端口` 只修改该节点的公网端口，本机后端端口由脚本维护。

Hysteria2 使用证书，但不需要 Nginx。将 `hy.example.com` 换成自己的域名，并将该记录设为“仅 DNS”。示例监听 UDP 24453：

```bash
xray a hy2 24453 --domain hy.example.com
```

### 修改域名、路径和网站

将下面的 `n001` 换成实际使用 Nginx 的节点 ID：

| 命令 | 用途 |
|---|---|
| `xray host n001 new.example.com` | 修改节点域名，按需签发新证书 |
| `xray path n001 /new-path` | 修改节点路径或 gRPC 服务名 |
| `xray web n001 static` | 使用默认本地静态网站 |
| `xray web n001 www.example.org` | 将网站反代到指定 HTTPS 域名 |

网站按域名共享，修改 `web` 会影响同域名下所有节点的伪装网站。

### 查看与维护证书

```bash
xray cert list
xray cert renew node.example.com
xray cert deploy node.example.com
```

证书会自动续期；`renew` 检查并续期，`deploy` 重试部署已签发证书。删除全部相关节点后，可按顺序清理不再使用的网站和证书：

```bash
xray domain delete node.example.com
xray cert delete node.example.com
```

仍被引用的资源会拒绝删除。

## 服务、日志和维护

| 命令 | 用途 |
|---|---|
| `xray status` | 查看服务状态 |
| `xray start`／`xray stop`／`xray restart` | 启动／停止／重启整个 Xray 服务 |
| `xray restart nginx` | 重启 Nginx，也支持 `start nginx`、`stop nginx` |
| `xray log`／`xray logerr` | 持续查看访问／错误日志，按 Ctrl+C 退出 |
| `xray test` | 检查当前配置 |
| `xray recover` | 恢复未完成的管理操作 |
| `xray fix n001` | 重建指定节点 |
| `xray dns cloudflare` | 将全局 DNS 改为 Cloudflare DoH |
| `xray dns none` | 恢复使用服务器 DNS |
| `xray version` | 查看脚本和核心版本 |
| `xray update core` | 安装兼容清单中的核心版本 |
| `xray update dat` | 更新规则数据 |
| `xray uninstall` | 卸载受管程序和服务，保留配置备份、证书与凭据 |

停止／重启 Xray、修改全局 DNS 和更新核心会影响所有节点。

更新脚本需要指定已发布的版本标签，例如：

```bash
xray update sh v0.1.1
```

`v0.1.1` 是当前版本示例，有新版时换成对应标签。可在 [Releases](https://github.com/tktkl/Xray/releases) 查看已发布版本。

已安装 v0.1.0 的用户执行上面的更新命令后，重新运行 `xray` 即可使用编号菜单，已有节点会保留。

完整参数见 `xray help`；更多资料：[命令兼容表](docs/COMPATIBILITY.md) · [协议与出口能力](docs/PROTOCOLS.md) · [开发与测试](docs/DEVELOPMENT.md)。
