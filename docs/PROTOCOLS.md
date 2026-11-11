# 协议与出口能力

| 入口别名 | 业务协议 | 传输 | TLS 位置 |
|---|---|---|---|
| reality/r | VLESS Vision | TCP/REALITY | Xray，无需域名证书 |
| tcp | VMess | TCP | 无 |
| kcp | VMess | mKCP/UDP | 无 |
| ws/grpc | VMess | WS/gRPC | Nginx |
| vws/vgrpc/xhttp | VLESS | WS/gRPC/XHTTP | Nginx |
| tws/tgrpc | Trojan | WS/gRPC | Nginx |
| ss | Shadowsocks/SS2022 | TCP/UDP | 无 |
| hy2 | Hysteria2 | QUIC/UDP | Xray + Certbot |
| socks | SOCKS5，强制认证 | TCP/UDP | 无 |
| door | 固定目标转发 | TCP/UDP | 无 |

业务 TCP/UDP 与入口传输不是同一概念；例如 VLESS TCP 隧道可以承载业务 UDP。转发是否可用还取决于上游配置。

出口导入支持 SS SIP002、VMess v2 JSON Base64、VLESS、Trojan、SOCKS5 和 HTTP CONNECT。VLESS/VMess/Trojan 支持核心可用的 TCP/WS/gRPC/XHTTP 组合及 TLS，VLESS 支持 REALITY。未知参数、SS plugin、跳过 TLS 校验的链接明确拒绝。

HTTP CONNECT 只有 TCP；配置到入口后业务 UDP 由规则阻断，不自动回退。SOCKS5 的 UDP 可用性取决于上游 UDP ASSOCIATE 支持和可达性。SS2022 的密码必须是与算法匹配的 Base64 密钥。

动态端口、旧 HTTP/H2/QUIC transport 和已移除的旧式伪装 header 不伪装成可用功能。当前 mKCP 使用 seed 与核心默认封装。
