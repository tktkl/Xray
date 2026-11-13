# 命令兼容

基线：233boy/Xray v1.37，commit `66e04223735ba551762fa08cf46dce57827bc6c6` 的实际有效命令。内部代码独立实现。

| 原命令 | 本脚本行为 |
|---|---|
| a/add, c/config/change, d/del/rm, dd/ddel, i/info | 保留；节点使用稳定 ID 和名称 |
| port/id/passwd/method/key/sni/host/path/new/full/seed/type/web | 保留；port 只影响该节点公网端口 |
| url/qr/client/genc/debug/gen | 保留；debug 脱敏、二维码本地生成 |
| start/stop/restart/status/test | 保留；管理前端参数改为 nginx |
| dns/log/logerr | 保留；修改为全局操作 |
| fix/fix-all/fix-config.json | 从源配置重建；fix-all 为全局操作 |
| fix-caddyfile | 提示改用 fix-nginx |
| update core/sh/dat | 固定兼容清单与摘要校验；sh 需要已发布版本 |
| update caddy | 提示改用 update nginx / cert |
| no-auto-tls | 创建本机后端，不接管前端 TLS |
| api/bin/pbk/x25519/tls/run/uuid | 核心透传 |
| xapi | 指向受管 Unix socket，操作不持久化 |
| ip/get-port/ss2022 | 保留 |
| reinstall | 保留源配置并重建验证；不清空服务器 |
| uninstall | 仅停用受管资源，保留恢复资料和共享软件包 |
| dp/dynamicport | 与上游当前行为一致，明确不支持 |
| bbr | 仅明确调用时配置 |

更新脚本需指定发布标签，例如 `xray update sh v0.1.3`；从公开 Release 下载并校验摘要，无需 GitHub Token。创建 Release 之前不会假装存在更新包。Cloudflare Token 仍只用于 DNS-01 签发，与程序下载安装无关。

名字精确匹配优先，多个匹配时交互选择；非交互必须提供明确 ID。快捷修改命令同样可通过 `xray c n001 OPTION VALUE` 使用。

交互菜单支持按序号选择协议、节点、适用修改项、出口、SS 加密方式、REALITY SNI、DNS、伪装网站，以及服务、证书、分享、日志和更新操作。主菜单明确显示 `0) 退出`，子菜单显示 `0) 上一步`，嵌套选择按层返回；返回操作不提交修改。交互选择节点时，即使只有一个节点也提供返回选项；提供精确节点 ID 的命令仍直接执行。错误序号可以重新输入，主菜单在操作完成后继续显示。原有协议别名、带参数命令和显式 `auto` 保持可用，不会额外要求选择菜单。
