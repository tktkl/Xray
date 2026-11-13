# 客户端与版本规则

脚本不设置客户端最低／最高版本，不按客户端版本拒绝连接或导出。

REALITY 服务端和客户端配置均不写入 `minClientVer`／`maxClientVer`。客户端配置只提供标准 JSON，使用当前核心的字段，不提供旧式 JSON 兼容分支。

```bash
xray url n001
xray client n001
xray genc n001
```

服务端继续使用已验证核心，以满足节点热更新、Unix socket 管理 API 和路由操作的能力要求。服务端核心与客户端无需相同版本，但客户端必须实现所选协议及传输。

## 核心协议边界

移除脚本层的版本限制，不会改变核心内置的握手规则。v26.11.9 使用的 [官方 REALITY 实现](https://github.com/XTLS/REALITY/blob/4bb46b2afd8b/tls.go#L217) 在进入可选版本判断前，会拒绝不满足 ClientHello 要求的握手。不能将“不设置版本上下限”表述成“所有历史客户端均能连接”。

该边界已在 2026-11-13 的 `nl` 检查中确认，生产节点保持原样。详细检查经过和历史测试结果见 [验证记录](VALIDATION.md)。

## 标准配置

- REALITY 客户端使用 `password` 字段，分享链接使用 `pbk`。
- WS 客户端使用独立的 `wsSettings.host`。
- mKCP 使用当前核心支持的 `finalmask`，节点的 seed 同步用于服务端和客户端。
- 已有原始 mKCP 节点保持原有网络格式，脚本更新不会自动转换；新建节点使用有效的 mask 配置。
- UUID、密钥、密码认证和 TLS 证书验证继续生效。
