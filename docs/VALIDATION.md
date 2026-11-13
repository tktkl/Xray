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

## 2026-11-13：v0.1.2 日志权限修复与安全检查

- 检查本项目 v0.1.1 和 233boy v1.37 的运行脚本、安装／更新流程及持久化入口；未发现明确恶意后门代码。两边公开脚本发布包均与对应源码逐字节一致，Xray 核心清单摘要与官方 `.dgst` 一致。具体范围及限制见 [安全检查记录](SECURITY-REVIEW.md)。
- 在 Docker 用 root 所有、0600 权限的占位文件复现旧版日志清理跟随服务用户符号链接的问题；修复后同一操作失败且保护文件内容保持不变。
- Ubuntu 24.04 容器通过 ShellCheck、23 项 Bats、PTY 交互和完整真实核心／Nginx／本地 CA 集成测试。新增用例验证正常清理、符号链接保护以及日志读取权限。
- 真实 systemd 容器中，从 v0.1.1 更新到本地候选 v0.1.2，核心 PID 和节点源文件保持不变；已安装命令通过修复后的保护检查。无外网容器中的节点、出口、二维码和脱敏命令验证通过。
- 正式发布工作流 [43354563234](https://github.com/tktkl/Xray/actions/runs/43354563234) 的八个环境全部通过；实际下载的 v0.1.2 两个附件摘要正确，26 个程序包文件及独立安装入口逐字节匹配修复标签。
- 从公开 Release 实际更新后，核心 PID 和节点源文件不变；再次验证日志链接无法清空 root 保护文件、普通日志仍可正常清理，配置检查通过。

## 2026-11-13：v0.1.3 分层返回与退出

- 主菜单明确显示 `0) 退出`；子菜单显示 `0) 上一步`。独立处理返回和 EOF，嵌套菜单按层返回，不再统一取消整次操作。
- PTY 实际输入覆盖节点选择／修改项／新协议、入口参数、出口链接、REALITY SNI、SS 加密方式、分享格式、日志级别、证书配置、DNS、更新版本和修复菜单的返回路径；逐次核对返回时没有提交节点或全局配置。
- 交互式单节点选择也显示返回选项，精确 ID 和非交互命令继续保留直接执行行为。非法端口在子进程中正常失败，不会被菜单的返回处理掩盖。
- 本地通过 ShellCheck、23 项 Bats、PTY 导航测试及真实 Xray／Nginx／TLS 回归；真实 systemd 容器验证已安装菜单及菜单内脚本更新，节点配置版本和核心 PID 均保持不变。
- 正式发布工作流 [43359353518](https://github.com/tktkl/Xray/actions/runs/43359353518) 的八个环境全部通过；实际下载附件的 SHA256 正确，26 个程序包文件及独立入口匹配发布标签。
- 从公开 Release 实际更新后，已安装菜单通过主菜单退出和多层返回验证，已提交节点配置与核心 PID 保持不变。

## 2026-11-13：v0.1.4 新旧客户端互通检查

- 通过 `ssh nl` 检查实际安装：脚本 v0.1.1、核心 v26.11.9，两个 REALITY 节点配置验证通过；服务用户为专用账号，Unix socket API 生效，未配置 `minClientVer`／`maxClientVer`。检查前后节点数量及核心 PID 保持不变，未更新或重启生产服务。
- 核对 XTLS 官方最新 Release、配置文档和 v26.11.9 使用的 REALITY 源码。发现最新 REALITY 底层会拒绝缺少 X25519MLKEM768 的 ClientHello，此边界不取决于脚本是否设置版本上下限。
- 修复客户端 JSON 仅使用 REALITY `password` 导致旧样本报缺少 `publicKey` 的问题。新增 `client/genc 节点ID legacy`，按旧布局导出 WS Host 和 mKCP seed，不设置客户端版本门槛。
- 新建 mKCP 使用官方 `finalmask`／`mkcp-legacy`，VMess 分享链接带有真实 seed；旧脚本已创建的原始 mKCP 节点保持原数据格式，避免无意断开现有客户端。
- 本地 Ubuntu 24.04 ARM64 通过 ShellCheck、25 项 Bats、PTY 和完整真实核心／Nginx／本地 CA 测试。额外使用官方且校验摘要的 v1.8.4、v1.8.24、v24.12.31 客户端连接当前服务端，VMess TCP／mKCP、VMess／VLESS／Trojan WS／gRPC、SS2022 和传统 SS AEAD 的 TCP／UDP 往返通过；v24.12.31 的 XHTTP TCP／UDP 也通过。
- 同时保留 REALITY 边界的反向测试：旧样本可以读取修复后的 JSON，但 TLS 握手被上游拒绝，不计为互通成功。对 `nl` 原有节点的公网测试也得到相同结果；当前客户端访问测试 HTTPS 页面成功。测试没有输出或提交生产节点凭据。
- 正式发布工作流 [43375059523](https://github.com/tktkl/Xray/actions/runs/43375059523) 的八个系统／架构组合通过，包含新增的三份旧客户端互通检查。公开 Release 两个附件摘要正确，27 个程序包文件和独立入口逐字节匹配标签。
- 从公开 Release 实际更新到 v0.1.4 后，原始及兼容 mKCP 节点源文件摘要、核心 PID 保持不变，旧式 JSON 导出及配置验证通过。生产 `nl` 的脚本仍是检查时的 v0.1.1；本次未在该机部署修复版本。

## 2026-11-13：v0.1.5 标准导出与版本规则

- 按用户要求移除 `current/legacy` JSON 格式选择、旧式导出菜单和旧字段转换分支，客户端导出只保留当前核心的标准格式。相关旧客户端样本下载及依赖该分支的测试同步移除；v0.1.4 的历史检查结果保留在上节。
- REALITY 服务端与客户端均不写入 `minClientVer`／`maxClientVer`，测试明确验证字段不存在。核心内置的协议握手行为不属于脚本版本限制。
- 本地通过 ShellCheck、25 项 Bats、PTY 和完整真实 Xray／Nginx／本地 CA 测试。真实 systemd 容器从 v0.1.4 更新到候选 v0.1.5，节点源文件摘要及核心 PID 保持不变，标准 JSON 导出正常，已移除的格式参数被明确拒绝且不输出凭据。
- 正式发布工作流 [43376934525](https://github.com/tktkl/Xray/actions/runs/43376934525) 的八个系统／架构组合全部通过。实际下载的 v0.1.5 两个附件摘要正确，27 个程序包文件及独立安装入口逐字节匹配发布标签。

## 2026-11-13：v0.1.6 默认更新最新正式版

- `update sh`、`U`、`update.sh` 省略版本时解析 GitHub 最新正式版，校验最终地址属于本仓库且是固定版本标签，再下载程序包和验证 SHA256。显式版本仍可使用；已是最新正式版时不替换程序文件。
- Ubuntu 24.04 容器通过 ShellCheck、31 项 Bats、PTY 和完整真实 Xray／Nginx／本地 CA 测试。新增测试覆盖查询失败、异常跳转地址、无效参数、显式版本固定下载、摘要错误及所有快捷命令；终端测试覆盖无版本提示和新菜单逐层返回。
- 真实 systemd 容器以本地 Release HTTP 夹具验证指定版本更新和不带版本号的实际升级，核心 PID、节点源文件摘要及已提交配置版本保持不变。重复执行最新更新和别名不会重复替换脚本；停止状态操作、恢复、timer 及卸载回归通过。
- GitHub `/releases/latest` 的真实 HTTPS 跳转可以解析到本仓库正式版；新安装命令使用 `/releases/latest/download/install.sh`，下载到的入口仍固定自身发布版本。发布包在线升级结果在正式附件发布后另行验证。

## 测试边界

- REALITY 客户端握手使用本地 TLS 1.3/H2 目标；测试开关只在 `/tmp/` 隔离状态目录生效。两个真实 Apple 站点的可达性必须在部署服务器检查。
- 证书测试使用本地 CA。真实 Cloudflare DNS-01、生产 ACME 限流及公网 DNS 传播需要自有测试域名和凭据，尚未执行。
- 八个发行版/架构组合已由正式发布 CI 验证；本地 Docker 的 amd64 仿真未启用，不将远端原生 CI 结果表述为本地运行。
- 故障注入模拟进程中断和服务启动恢复，不等同于真实存储设备突然断电。实现使用同步持久化及原子提交，但仍取决于宿主文件系统和存储设备的保证。
- SOCKS5 上游 UDP 可用性取决于上游实现；HTTP CONNECT 明确不支持 UDP。
- 真实 GitHub Release 在线下载及初次安装已验证；系统软件包升级与真实 ACME 签发仍需对应软件源/测试凭据。

复现入口：`tests/run.sh`、`tests/integration/systemd.sh`；CI：`.github/workflows/test.yml`。
