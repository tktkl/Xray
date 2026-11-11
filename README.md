# Xray 独立管理脚本

独立实现的 Bash＋jq 管理器。参考 233boy/Xray v1.37 的命令习惯，不加载或执行该项目的代码。一个核心进程管理多个节点；每次 `add` 只新增一个节点，入口与出口分别修改。

支持 Debian 12/13、Ubuntu 22.04/24.04，amd64/arm64，要求 systemd。核心及规则数据版本、SHA256 固定在 `config/releases.json`。普通节点操作不重启核心；核心升级、DNS、日志和整体服务管理是全局操作。

## 安装

公开仓库使用匿名下载，安装和升级均不需要 GitHub Token。

### 一键安装

在 VPS 运行以下一条命令，下载固定版本的独立入口，再自动下载完整程序包、校验 SHA256 并安装：

```bash
curl -fL --proto '=https' --proto-redir '=https' -o xray-install.sh https://github.com/tktkl/Xray/releases/download/v0.1.0/install.sh && sudo bash xray-install.sh
```

**在线安装需要对应版本的 GitHub Release 包含 `install.sh`、源码包和 `SHA256SUMS` 三份附件。仅推送代码不会生成发布附件；推送 `v0.1.0` 标签后由发布工作流生成。**

也可以只把 `bootstrap.sh` 拷到服务器运行，无需 Git 或完整源码：

```bash
sudo bash bootstrap.sh
```

入口只下载指定标签的 Release；版本未发布、网络失败、摘要不一致或包路径异常时停止，不回退到未校验的分支源码。

Cloudflare Token 仍在需要签发证书时配置，保持私密，不放进公开仓库或安装命令。只使用 REALITY、SS 等无需证书的协议时，不需要任何 Token。

指定其他已发布版本：

```bash
sudo bash bootstrap.sh --version v0.1.0
sudo xray help
```

开发者用 `bash scripts/package-release.sh v0.1.0` 生成源码包、独立入口 `install.sh` 和摘要；发布工作流会上传这三份附件。

### 从源码安装／离线缓存

```bash
git clone --depth 1 https://github.com/tktkl/Xray.git && sudo bash Xray/install.sh
sudo xray help
```

也支持经过相同 SHA256 校验的离线下载缓存：`sudo bash install.sh --offline-cache /path/to/cache`。已存在其他 Xray 命令或服务时拒绝覆盖。

只安装基本依赖，不预装 Nginx、Certbot，不改防火墙或 BBR。首次添加相关 TLS 协议时才安装对应组件。请在云防火墙及本机防火墙放行节点所需的 TCP/UDP 端口。

## 多节点与独立出口

```bash
sudo xray a reality 24443 --name first --address YOUR_PUBLIC_IP
sudo xray a reality 24444 --name second --address YOUR_PUBLIC_IP
sudo xray list
sudo xray ob n001 'ss://BASE64_METHOD_PASSWORD@upstream.example:12345'
sudo xray ob n002 'vless://UUID@upstream.example:443?security=reality&type=tcp&sni=example.com&pbk=KEY&sid=SHORTID'
sudo xray ob n002 direct
sudo xray port n001 24445
sudo xray new n001 ss
sudo xray url n001
```

ID 不随协议或端口变化。修改入口保留出口；导入同一个出口链接也会独立保存副本。分享链接应加引号，防止 Shell 解释 `&`。SOCKS 默认使用密码认证。

REALITY 默认 SNI 仅有 `apps.mzstatic.com`、`xp.apple.com`，在服务器上检查 TLS 1.3、H2 与证书后选择。不可用时添加失败，可按 `reality [port] [uuid] [sni]` 指定目标。

没有 NAT 时默认探测本机路由源地址；有 NAT 时必须使用 `--address` 指定客户端能连接的公网 IP 或域名。

## 域名、Nginx 与证书

REALITY、SS、SOCKS、VMess TCP/mKCP 无需自有域名、证书或 Nginx。WS/gRPC/XHTTP TLS 由 Nginx 终止 TLS，每个域名一个受管站点文件。同一文件内可有多个端口与节点路径。Hysteria2 直接使用证书，不需要 Nginx。

先为域名配置需要的 A/AAAA。本脚本不改解析和橙云状态；DNS-01 签发本身无需域名解析到本机。使用 Cloudflare 代理时，还需确保其支持节点的协议和端口；REALITY/Hysteria2 不通过普通橙云 HTTP 代理。

```bash
sudo xray cert setup --email admin@example.com
# 交互输入一个 Cloudflare API Token；只授予所需 Zone 的 DNS 编辑权限。
# 也可引用已有凭据：
sudo xray cert setup --email admin@example.com --credentials /root/.secrets/certbot/cloudflare.ini
sudo xray a vws node.example.com auto /node-one
sudo xray a vgrpc node.example.com auto /node-two
sudo xray a hy2 24446 --domain hy.example.com
sudo xray cert list
```

凭据格式为 `dns_cloudflare_api_token = TOKEN`，要求 root 所有、0600。**不要把 Token 放进命令参数、提交到仓库或分享调试输出。** 所有受管证书共用一份配置。

使用 Certbot DNS-01、60 秒传播等待、ECDSA 单域名证书和系统 `certbot.timer`。签发与部署分离，成功签发的钩子只排队，部署失败每五分钟重试，不重新申请证书。手动重试：

```bash
sudo xray cert renew node.example.com
sudo xray cert deploy node.example.com
sudo xray web n001 static
sudo xray web n001 www.example.org
```

伪装网站按域名共享，出口按节点独立。`port` 修改公网端口，后端端口内部管理；分享链接不会使用后端端口。`no-auto-tls` 只创建本机后端，供自行管理前端使用。

删除节点保留共享网站和证书。无引用后可显式使用 `xray domain delete DOMAIN`、`xray cert delete DOMAIN`。不会自动接管已有站点或证书。

## 隔离、规则与恢复

默认阻止 BT、中国 IP 和内网业务目标；域名解析使用服务器 DNS，这不代表 DNS 经过节点上游。HTTP 出口只支持 TCP，UDP 明确阻断。上游故障不自动转为直连。GeoIP 和流量识别存在准确性边界。

节点源文件、完整运行配置和站点文件按版本保存，`current` 指向最后提交版本。API 热更新失败会回滚；超时查询实际状态。执行中断后运行 `sudo xray recover`。无法恢复时保留事务记录并拒绝新写，普通节点命令不会偷偷重启全部节点。

当前节点的已有连接可能断开；其他节点不应被主动断开。单核心进程仍有共享故障边界。

Xray 以专用用户运行，API 为仅服务用户与 root 可访问的 Unix socket。源节点文件与凭据仅 root 可读，诊断输出脱敏。`info/url/qr/client` 是明确的凭据导出功能，请谨慎分享。

## 验证

```bash
bash tests/fetch.sh arm64             # amd64 主机改为 amd64
docker compose build test
docker compose run --rm test
docker compose up -d systemd
docker compose exec systemd bash /src/tests/integration/systemd.sh
docker compose down
```

测试使用独立容器；NET_ADMIN 用于在容器回环接口上添加测试地址，systemd 测试容器需要 privileged 与私有 cgroup。不会使用生产 Cloudflare Token。证书测试使用本地 CA，真实 DNS-01 签发需单独配置测试域名与凭据。

CI 配置覆盖四个系统与两个架构。具体已执行的结果和限制见 `docs/VALIDATION.md`，配置 CI 并不等于所有环境已通过。

详细命令见 `xray help` 和 `docs/COMPATIBILITY.md`；协议与出口能力见 `docs/PROTOCOLS.md`。

脚本升级：`sudo xray update sh v0.1.0`，匿名下载指定公开 Release 并校验，不需要 GitHub Token。核心和规则数据使用清单中的上游固定版本及摘要。
