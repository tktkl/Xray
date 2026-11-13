# 验证记录

本地验证日期：2026-11-10。Docker Desktop，Linux ARM64，cgroup v2。没有在 VPS 上部署或调用真实 Cloudflare Token。

## 已完成

- ShellCheck（warning 级别）、Bash 语法检查、Python 测试夹具语法检查。
- Debian 12 ARM64 与 Ubuntu 24.04 ARM64 容器中的真实 Xray 26.11.9、Nginx 和本地 CA 集成验证。
- 12 项 Bats 测试：URI/IPv6/SS2022/编码、输入注入、默认阻断、REALITY 随机值、域名站点、Certbot 钩子不争锁、精确选择、脱敏、Trojan/VMess 导入、证书部署中断恢复。
- 连续添加三个 REALITY 节点，独立修改端口、UUID、协议及出口；其他节点的长连接持续传输。
- 实际 SS、VLESS、SOCKS5 和 HTTP 出口；出口故障不回退直连。
- 实际内网、CN IP、域名解析到 CN 的阻断；BT 握手被阻断而普通 TCP 正常。
- API 请求成功但响应丢失的对账，入口/路由请求失败的回滚。
- prepared、outbounds、inbounds、routes、nginx、applied、committed 七个 SIGKILL 故障点后的持久化恢复。
- 同域名单 Nginx 文件、多公网端口、路径冲突检测、证书续期切换的实际 TLS 指纹核对、错误私钥保留旧版本并进入待重试队列。
- Nginx 路由修改和证书续期期间，另一个节点的流式连接保持传输；XHTTP 流式响应持续到达，没有完整响应缓冲。
- 以下 12 种入口各通过真实客户端 TCP 与 UDP 往返：VLESS-REALITY、VMess-TCP、VMess-mKCP、VMess-WS-TLS、VMess-gRPC-TLS、VLESS-WS-TLS、VLESS-gRPC-TLS、VLESS-XHTTP-TLS、Trojan-WS-TLS、Trojan-gRPC-TLS、Shadowsocks 2022、Hysteria2。
- 真实 systemd PID 1 容器：离线摘要校验安装、专用用户/Unix socket、普通节点修改保持核心 PID、服务停止时修改保持停止、DNS/日志全局应用、核心/规则升级、timer、配置持久化和安全卸载。
- systemd 启动前存在未提交候选版本时，恢复服务先还原已提交版本，再启动核心。

## 2026-11-11：公开仓库一键安装

- 新增独立 `bootstrap.sh` 和可复现发布打包入口，安装与脚本升级默认匿名访问固定标签的 Release，无需 GitHub 凭据。
- Debian 12 ARM64、Ubuntu 24.04 ARM64 中的 10 项引导器测试通过：匿名安装、错误/重复摘要、网络失败、路径穿越、符号链接、非法版本、下载而不执行、旧凭据参数拒绝及显式摘要。
- Ubuntu 24.04 的真实 systemd 容器通过发布包安装、原子切换脚本版本（保持核心 PID）、核心/规则更新、启动恢复及安全卸载。
- 上述 Release HTTP 下载使用本地测试夹具，核心和规则文件仍由固定摘要校验；不能以该测试替代真实 GitHub Release 附件的在线验证。
- CI 长连接夹具改为由测试主动结束，避免慢环境超过原 60 秒上限导致误判；本地半核容器超过 100 秒的核心隔离、API 对账和七处中断恢复测试通过。
- Release 工作流先运行四个发行版、两个架构的完整 CI，全部成功后才发布安装附件。

## 2026-11-11：v0.1.0 正式发布

- 标签 `v0.1.0` 对应提交 `48576e5943072feb7f4f74a983a0751a2aa500fe`。正式发布工作流 [42946938147](https://github.com/tktkl/Xray/actions/runs/42946938147) 成功，Debian 12/13、Ubuntu 22.04/24.04 的 amd64/arm64 共八个环境通过完整集成及 systemd 测试。
- 从公开 GitHub Release 实际下载 `install.sh`、`SHA256SUMS`、`xray-manager-v0.1.0.tar.gz`，核对两个 SHA256，并确认运行源码与经过测试的标签一致。
- 干净的 Ubuntu 24.04 ARM64 systemd 容器从真实 Release 在线下载安装入口和程序包，核心及规则使用已校验的离线缓存；服务启动、节点添加/查看/校验/删除及卸载通过。

## 2026-11-13：v0.1.1 编号菜单

- Ubuntu 24.04、Debian 12 Docker 容器中通过 ShellCheck、22 项 Bats 和完整真实核心／Nginx／本地 CA 集成测试。
- 新增 PTY 模拟终端测试，实际输入序号覆盖全部 14 种协议、节点选择、按协议筛选的修改项、端口输入、切换协议、SS 加密方式、REALITY SNI、出口导入、DNS 和日志设置。验证服务／证书／更新等子菜单、非法序号重选、取消、EOF、主菜单继续操作及原命令参数／`auto` 兼容。
- 回归 `xray c n001` 的位置参数错误，验证修改一个节点不改变其他节点，并验证取消选择不会提交新配置。
- 真实 systemd 容器通过 v0.1.1 发布包安装、脚本原子更新、核心／规则更新、停止状态修改、开机恢复、timer 和卸载。
- 使用已发布且核对 SHA256 的 v0.1.0 程序包安装，创建节点后通过原版 `xray update sh v0.1.1` 更新到本地候选发布包；节点源文件摘要及核心 PID 保持不变。此项更新下载使用本地 HTTP 夹具，不替代正式 Release 在线下载验证。
- 正式发布工作流 [43347611121](https://github.com/tktkl/Xray/actions/runs/43347611121) 成功，Debian 12／13、Ubuntu 22.04／24.04 的 amd64／arm64 八个组合通过完整测试后发布 v0.1.1 附件。
- 实际下载 v0.1.1 的安装入口、程序包及 `SHA256SUMS`，两个附件摘要匹配；systemd 容器从公开 Release 完成在线脚本更新，以及 root 安装、添加／校验／删除节点和卸载。核心与规则文件使用已校验缓存，在线脚本更新保持节点源文件和核心 PID 不变。

## 测试边界

- REALITY 客户端握手使用本地 TLS 1.3/H2 目标；测试开关只在 `/tmp/` 隔离状态目录生效。两个真实 Apple 站点的可达性必须在部署服务器检查。
- 证书测试使用本地 CA。真实 Cloudflare DNS-01、生产 ACME 限流及公网 DNS 传播需要自有测试域名和凭据，尚未执行。
- 八个发行版/架构组合已由正式发布 CI 验证；本地 Docker 的 amd64 仿真未启用，不将远端原生 CI 结果表述为本地运行。
- 故障注入模拟进程中断和服务启动恢复，不等同于真实存储设备突然断电。实现使用同步持久化及原子提交，但仍取决于宿主文件系统和存储设备的保证。
- SOCKS5 上游 UDP 可用性取决于上游实现；HTTP CONNECT 明确不支持 UDP。
- 真实 GitHub Release 在线下载及初次安装已验证；系统软件包升级与真实 ACME 签发仍需对应软件源/测试凭据。

复现入口：`tests/run.sh`、`tests/integration/systemd.sh`；CI：`.github/workflows/test.yml`。
