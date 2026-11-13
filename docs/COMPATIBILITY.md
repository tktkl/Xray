# 命令兼容

基线：233boy/Xray v1.37，commit `66e04223735ba551762fa08cf46dce57827bc6c6` 的实际有效命令。内部代码独立实现。

| 原命令 | 本脚本行为 |
|---|---|
| a/add, c/config/change, d/del/rm, dd/ddel, i/info | 保留；节点使用稳定 ID 和名称 |
| port/id/passwd/method/key/sni/host/path/new/full/seed/type/web | 保留；port 只影响该节点公网端口 |
| url/qr/client/genc/debug/gen | 保留；客户端只导出标准 JSON，debug 脱敏、二维码本地生成 |
| start/stop/restart/status/test | 保留；管理前端参数改为 nginx |
| dns/log/logerr | 保留；修改为全局操作 |
| fix/fix-all/fix-config.json | 从源配置重建；fix-all 为全局操作 |
| fix-caddyfile | 提示改用 fix-nginx |
| update core/sh/dat；U/update.sh | core 默认官方最新正式版，检查新字段及本机配置/API；sh 默认最新脚本；dat 使用固定摘要 |
| update caddy | 提示改用 update nginx / cert |
| no-auto-tls | 创建本机后端，不接管前端 TLS |
| api/bin/pbk/x25519/tls/run/uuid | 核心透传 |
| xapi | 指向受管 Unix socket，操作不持久化 |
| ip/get-port/ss2022 | 保留 |
| reinstall | 保留源配置并重建验证；不清空服务器 |
| uninstall | 仅停用受管资源，保留恢复资料和共享软件包 |
| dp/dynamicport | 与上游当前行为一致，明确不支持 |
| bbr | 仅明确调用时配置 |

`xray update sh`、`xray U`、`xray update.sh` 默认查询最新正式版，也接受 `latest`；指定版本如 `xray update sh v0.1.7` 仍然可用。查询成功后固定到具体发布标签，从公开 Release 下载并校验摘要，无需 GitHub Token。已是最新正式版时无需重复下载；网络或发布地址异常时停止，不回退分支源码。Cloudflare Token 仍只用于 DNS-01 签发，与程序下载安装无关。

`xray update core` 默认查询 XTLS/Xray-core 官方最新正式版，不受脚本内已测试版本清单限制。清单外版本使用对应架构的官方 `.dgst` 中唯一 SHA2-256；比对该版本源码与脚本基线的 Go JSON 字段声明，显示新增字段并保存完整报告。`xray update core --check` 只检查，`xray update core v26.11.9` 指定版本；替换前在专用用户下验证现有配置和真实隔离 API，替换后核对入口、出口和完整路由。失败回滚，回滚失败保留恢复记录。检查不等同于该未知版本已完成全部 CI，也不涵盖字段语义和枚举变化；新增字段需脚本另行适配。

名字精确匹配优先，多个匹配时交互选择；非交互必须提供明确 ID。快捷修改命令同样可通过 `xray c n001 OPTION VALUE` 使用。

交互菜单支持按序号选择协议、节点、适用修改项、出口、SS 加密方式、REALITY SNI、DNS、伪装网站，以及服务、证书、分享、日志和更新操作。主菜单明确显示 `0) 退出`，子菜单显示 `0) 上一步`，嵌套选择按层返回；返回操作不提交修改。交互选择节点时，即使只有一个节点也提供返回选项；提供精确节点 ID 的命令仍直接执行。错误序号可以重新输入，主菜单在操作完成后继续显示。原有协议别名、带参数命令和显式 `auto` 保持可用，不会额外要求选择菜单。

脚本不设置 REALITY 的 `minClientVer`／`maxClientVer`，不按客户端版本拒绝连接或导出。`client/genc [节点]` 仅提供标准 JSON，没有格式选择参数。REALITY 底层握手及协议实际能力仍有边界，见 [客户端与版本规则](CLIENT-COMPATIBILITY.md)。
