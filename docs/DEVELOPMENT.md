# 开发与测试

用户安装和日常命令见 [README](../README.md)。本文说明源码安装、离线缓存、测试、打包和实现约定。

## 源码安装与离线缓存

在支持的 Linux 系统上执行。以下以有 sudo 权限的开发用户为例，root 用户去掉 `sudo`。

```bash
git clone --depth 1 https://github.com/tktkl/Xray.git
cd Xray
sudo bash install.sh
sudo xray help
```

仓库中的 `install.sh` 是源码安装入口，需要相邻的 `bin`、`lib`、`jq` 等目录。Release 附件中的 `install.sh` 则由 `bootstrap.sh` 生成，可独立下载运行。

源码安装支持离线核心和规则数据缓存，文件名及 SHA256 必须与 [版本清单](../config/releases.json) 一致：

```bash
bash tests/fetch.sh arm64
sudo bash install.sh --offline-cache "$PWD/.cache"
```

amd64 主机将 `arm64` 换成 `amd64`。缓存只涵盖核心与规则文件，系统依赖仍通过发行版软件源安装。已有其他 Xray 命令或服务时拒绝覆盖。

独立引导器只下载固定标签的公开 Release，无需 GitHub Token：

```bash
sudo bash bootstrap.sh --version v0.1.4
```

未发布版本、网络失败、摘要异常或包路径不安全时停止，不回退到分支源码。可以通过 `--sha256` 指定另行核实的程序包摘要。摘要校验用于完整性检查，不能证明代码没有后门。

## 本地验证

测试前需要 Docker Compose、Bash、jq、curl 和 OpenSSL。在仓库根目录运行：

```bash
bash tests/fetch.sh arm64
docker compose build test
docker compose run --rm test
docker compose up -d systemd
docker compose exec systemd bash /src/tests/integration/systemd.sh
docker compose down
```

amd64 主机将下载参数改为 `amd64`。默认镜像基于 Ubuntu 24.04，可通过 `TEST_BASE` 和 `TEST_TAG` 选择其他测试环境。

`tests/fetch.sh` 同时获取 `tests/client-releases.json` 中带固定 SHA256 的旧客户端样本，放入 `.cache/client-版本-架构.zip`。完整 TLS 测试在当前服务端上验证旧客户端实际 TCP／UDP 传输；REALITY 上游握手不兼容被明确记录为边界，不算互通成功。这份清单仅用于测试，不会限制生产客户端版本。

`tests/run.sh` 包含 ShellCheck、Bats、PTY 交互、真实 Xray 和 Nginx／本地 CA 集成测试。`tests/integration/interactive.py` 用模拟终端输入序号，覆盖协议与修改菜单、参数提示、逐层返回、主菜单退出、单节点返回、EOF、输错重选及命令参数兼容，并验证返回时不提交节点或全局修改。`NET_ADMIN` 用于给容器回环接口添加测试地址；systemd 容器使用 privileged 和私有 cgroup。

证书测试使用本地 CA，不使用生产 Cloudflare Token。真实 DNS-01 签发需要明确配置的测试域名与凭据。已执行的结果及测试边界见 [验证记录](VALIDATION.md)。

## CI 与发布

[测试工作流](../.github/workflows/test.yml) 覆盖 Debian 12／13、Ubuntu 22.04／24.04，以及 amd64／arm64。配置了 CI 不代表每次运行都已通过，具体结果应查看对应工作流。

发布标签必须与 `lib/common.sh` 中的版本一致。本地打包：

```bash
bash scripts/package-release.sh v0.1.4
```

默认在 `dist/` 生成：

- `xray-manager-v0.1.4.tar.gz`：程序源码包。
- `install.sh`：独立安装入口。
- `SHA256SUMS`：两个附件的 SHA256。

[发布工作流](../.github/workflows/release.yml) 在版本标签对应的完整 CI 全部成功后上传这些附件。不要修改已发布标签或覆盖现有附件；代码更新使用新版本。

## 实现约定

- Bash＋jq 模块独立实现，参考 233boy/Xray v1.37 的命令习惯，不加载或执行上游脚本。兼容范围见 [命令兼容表](COMPATIBILITY.md)。
- 一个核心进程管理多个独立节点。节点源配置、完整运行配置、Nginx 站点及证书版本引用按版本保存，`current` 指向最后提交版本。
- 普通节点操作通过受限 Unix socket API 更新。API 超时先查询运行状态；失败回滚，执行中断后从事务记录恢复，不自动重启整个核心。
- 修改入口可能断开目标节点连接，其他节点不应被主动断开。核心故障、核心更新、全局 DNS 和整体服务操作仍有共享影响范围。
- Xray 使用专用非 root 用户。节点源配置和 Cloudflare 凭据仅 root 可读；运行配置和私钥按服务需要授权。JSON 使用 jq 参数构造，Shell 参数使用数组和 `"$@"` 传递，不使用 `eval`。
- 每个业务入口显式绑定出口，默认出口为阻断。业务规则默认阻止 BT、中国 IP 和内网目标；`IPOnDemand` 会根据 DNS 结果检查目标 IP。GeoIP 数据和流量识别存在准确性边界。
- 默认 DNS 使用服务器解析，属于基础设施直连行为。HTTP 出口不支持 UDP；代理出口故障时不回退直连。具体组合见 [协议与出口能力](PROTOCOLS.md)。
- Nginx 按受管域名生成文件。WS、gRPC 和 XHTTP 使用各自的反代配置，网站按域名共享；节点出口仍独立。
- Certbot 使用 Cloudflare DNS-01、60 秒传播等待、ECDSA 单域名证书和系统 `certbot.timer`。签发与部署分离：签发钩子只排队，部署失败由部署任务每五分钟重试，不重新申请证书。
- 安装仅按需添加 Nginx／Certbot，不自动开启 BBR 或修改防火墙。卸载仅移除受管程序、服务和站点入口，保留恢复资料、证书、凭据及共享软件包。

配置示例见 [examples](../examples/)，固定下载版本和 SHA256 见 [config/releases.json](../config/releases.json)。
