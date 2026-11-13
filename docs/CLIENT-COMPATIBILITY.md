# 客户端兼容说明

脚本不设置客户端版本上下限，不加入客户端版本检测或拒绝规则。这里列出的版本仅是测试样本，不是最低版本要求。

## 服务端与客户端是两条独立边界

服务端安装使用经过验证的 Xray 核心和固定摘要，当前为 v26.11.9。这保证 Unix socket 管理 API、逐节点热更新、路由替换和配置验证能力。把服务端核心任意降级，可能使这些管理能力或协议不存在；不能通过删除版本检查解决。

客户端不需要与服务端使用相同版本，但需要实现所选协议、传输和加密方式。导出的配置不包含 `minClientVer`／`maxClientVer`，服务端 REALITY 配置也不包含这两个限制。

## 分享链接和 JSON

通常优先将 `xray url 节点ID` 的结果导入客户端，让客户端生成适合自身内核的配置。

直接使用 Xray JSON 时：

```bash
xray client n001
xray client n001 legacy
xray genc n001 legacy
```

- 默认 `current` 使用当前核心支持的配置布局。
- `legacy` 将 WS Host 放入 `headers.Host`，将兼容 mKCP 的 mask 参数转换为 `kcpSettings.seed`／`header`。
- REALITY 导出使用当前核心仍接受的 `publicKey` 别名，修复旧核心无法识别仅含 `password` 的客户端配置问题；分享链接继续使用 `pbk`。
- 格式选择不修改服务端，不调整协议安全性，不设置版本限制，也不能为客户端增加原本不存在的协议实现。

## REALITY 的实际限制

本次核对的 [官方最新 Release](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9) 是 v26.11.9。其使用的 [REALITY 实现](https://github.com/XTLS/REALITY/blob/4bb46b2afd8b/tls.go#L217) 在进入可选版本检查前，要求 ClientHello 带有 `X25519MLKEM768`，会拒绝不满足这一条件的握手。

因此，不填写版本限制，也不等于能接收所有早期 REALITY 客户端。脚本没有关闭这一底层行为的配置项，不能把 `minClientVer` 留空宣传为“任意旧客户端均可用”。本次也没有修改或绕过上游密码学实现。

2026-11-13，在 `nl` 已有 REALITY 节点上保持服务端不变进行实际连接：当前 v26.11.9 客户端访问测试 HTTPS 页面成功；v1.8.4、v1.8.24 和 v24.12.31 在修正 JSON 字段后能读取配置，但握手仍失败。服务端的版本上下限均未设置。

这些客户端可使用自己支持的其他协议入口。不要为了旧客户端兼容而关闭证书校验或移除认证。

## mKCP

[官方 mKCP 文档](https://xtls.github.io/config/transports/mkcp.html) 已移除旧 `seed`／`header` 的配置行为，改由 [FinalMask](https://xtls.github.io/config/transports/finalmask.html#mkcp-legacy) 实现兼容封装。旧脚本虽然写入了 seed，当前核心实际上不会用它生成旧式封装；仅用同版本客户端自测无法发现这类问题。

v0.1.4 起，新建节点使用 `mkcp-legacy` 和随机 seed，旧客户端导出使用同一 seed。已有旧节点保持原始网络格式，避免脚本更新导致已有客户端断连。需要转换时，仅修改目标节点：

```bash
xray seed n001 auto
xray client n001 legacy
```

修改 seed 后需同步更新客户端。已有原始 mKCP 节点不能仅通过 JSON 重命名变成旧式加密封装，导出会给出明确提示。

## 选择入口

| 入口 | 客户端需要的能力 |
|---|---|
| Shadowsocks AEAD，例如 `chacha20-ietf-poly1305` | 对应 AEAD 算法；不要求 SS2022 |
| Shadowsocks 2022 | 对应 SS2022 算法；传统 SS 客户端不自动支持 |
| VMess TCP／WS／gRPC | VMess AEAD、所选传输与 TLS |
| VLESS／Trojan WS／gRPC＋TLS | 对应业务协议、传输与 TLS |
| VMess mKCP | 对应 mKCP 封装及相同 seed |
| XHTTP | 对应 XHTTP 实现和互通的传输模式 |
| Hysteria2 | Hysteria2 实现；客户端应用也可能使用独立的 Hysteria 内核 |
| VLESS-REALITY | REALITY、Vision，以及服务端实现接受的 TLS 握手 |

WS／gRPC 在当前核心仍可使用，但官方已标记为不推荐并建议转向 XHTTP。为兼容已有客户端保留它们，不代表可以用 XHTTP 替换旧客户端尚未实现的传输。

用户指定的 Apple SNI 候选继续保留，未自动修改；当前官方核心对部分 Apple 目标会输出封锁风险警告，该警告与客户端版本上下限无关。

## 验证范围

测试同时启动当前服务端与官方旧客户端样本，检查实际 TCP／UDP 往返。旧核心附件有固定 SHA256，只用于测试；清单位于 `tests/client-releases.json`。部分旧样本没有 Hysteria2 或 XHTTP，不能将其未实现能力算成格式兼容成功。REALITY 的拒绝行为作为独立边界验证，不计为互通通过。

v0.1.4 的 [八环境发布 CI](https://github.com/tktkl/Xray/actions/runs/43375059523) 已通过，结果如下。这些是已测试样本，不是客户端最低版本要求。

| 入口 | v1.8.4／v1.8.24／v24.12.31 样本结果 |
|---|---|
| VMess TCP／mKCP | 三个样本 TCP／UDP 通过 |
| VMess／VLESS／Trojan WS／gRPC＋TLS | 三个样本 TCP／UDP 通过，使用 legacy JSON |
| SS2022／传统 SS AEAD | 三个样本 TCP／UDP 通过 |
| VLESS XHTTP＋TLS | v24.12.31 TCP／UDP 通过；另两个样本未实现该传输 |
| VLESS-REALITY | 三个样本 JSON 可读取，当前上游核心拒绝旧 TLS ClientHello |
| Hysteria2 | 当前客户端通过；旧样本未实现该协议 |

实际下载的公开 Release 附件摘要及全部 27 个程序包文件与标签匹配。systemd 容器从公开 Release 更新后，原始及兼容 mKCP 节点源配置和核心 PID 均保持不变，旧式 JSON 导出正常。
