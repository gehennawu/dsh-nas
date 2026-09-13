# dsh-nas：Linux NAS 部署模板（dsh + Caddy + Authelia）

dsh 是可执行任意命令的 AI Agent。将其暴露于公网时，失陷代价为整台 NAS，因此认证不能仅依赖单层 Basic Auth。

本模板面向 **Linux NAS**：dsh 仅监听 `127.0.0.1`，公网入口为 Caddy + Authelia 双因素认证，宿主控制权保留在 NAS 命令行。

```text
浏览器 ──HTTPS──> Caddy ──forward_auth──> Authelia（127.0.0.1:9091，TOTP）
                    └────reverse_proxy──> dsh（仅监听 127.0.0.1:3080）
```

前置反代/Tunnel 模式（[模式 3](#进入方式)）下，公网 TLS 由前置入口终结后转发至 NAS 上的 Caddy。

宿主机无需安装 Node.js/npm：dsh 的安装、patch 与版本核验均在容器内执行。

**目录**

- [先看这里](#先看这里) — 耗时、前置条件
- [部署](#部署) — 单条命令与向导流程
- [进入方式](#进入方式) — 三种入口模式的选型
- [登录](#登录) — Authelia 双因素与 dsh 会话链接
- [日常运维](#日常运维) — 重启、升级、日志
- [故障排查](#故障排查) — 现象与处理对照
- [安全清单](#安全清单) — 配置变更前的检查项
- [附录](#附录) — 参数、代理、构建、镜像清理、目录结构

---

## 先看这里

首次构建镜像约 10 分钟（需在 NAS 上编译 native 依赖）。重启及运行参数变更（代理、cookie 有效期）不需要重新构建，仅更换 dsh 版本或修改反代域名需要重建。

部署前确认：

| 要求 | 说明 |
|---|---|
| 可执行 Docker 命令 | SSH 或本地终端。`deploy.sh` 校验 daemon、Engine 版本与 Compose；缺项时在交互终端提供自动补救（get.docker.com 安装/升级 Engine、启动 daemon、apt 安装 compose 插件、加入 docker 组），执行后自动复查，非交互环境直接报错退出 |
| 两个主机名 | `dsh.<域名>` 与 `auth.<域名>`。前置反代模式解析至公网 TLS 入口，其余模式解析至 NAS |
| 代理（可选） | 直连可跳过。使用代理时，构建阶段必须使用构建容器可达的地址，见[代理怎么填](#代理怎么填) |
| 端口 | 直连 443-only 需 443；直连 80/443 需 80 与 443；前置反代模式无需公网 IP，跨机时仅对前置入口开放 13080 |

系统与平台要求见[支持范围](#支持范围)。

## 支持范围

**支持**：Linux 主机、rootful Docker Engine ≥ 20.10、Docker Compose V2（插件或 V2 独立版）、Bash 与 GNU `sed`/`grep`/`awk`/`stat`、x86_64 与 ARM64、`network_mode: host`；项目目录与 `data/`、`authelia/data/`、`caddy/` 位于本地可写文件系统（非只读挂载、可 `chown`）。dsh 容器内以 UID 1000 运行，`data/dsh` 与 `data/workspace` 须允许 UID 1000 写入。

运行镜像不含 Docker CLI 与 Compose，主容器不挂载 Docker socket，升级仅能在宿主机命令行执行。

**不支持**：TrueNAS CORE 及非 Linux Docker 主机、rootless Docker、不支持 host 网络的容器平台、仅有 BusyBox 而缺 Bash/GNU 工具的环境、无法使用 Compose V2 的 NAS 管理界面、无域名且无可用前置 TLS 代理的部署。

## 部署

```sh
git clone https://github.com/gehennawu/dsh-nas.git
cd dsh-nas
chmod +x deploy.sh
./deploy.sh
```

> 项目目录与运行数据须位于本地可写文件系统（非只读挂载），且可 `chown`。

向导依次询问：

1. **出站代理**：直连选择不使用代理，使用代理则填写地址。首次构建需下载 apt 与 npm 包。
2. **根域名、证书邮箱、Authelia admin 密码**：密码用于 Authelia 双因素登录。
3. **入口模式**：三种模式择一，选型见下一节。
4. **反代域名 patch**：向导提示为 `是否启用 patch？[y/N]`，默认方案输入 `y`（直接回车表示不启用）。该 patch 使 dsh 在非 `localhost` 域名下仍判定为本机；不启用则保持原始 loopback-only 行为，设置页持久化与「在 NAS 上打开文件」等特权功能在公网域名下失效。填写反代使用的 hostname（如 `dsh.example.com`，纯 hostname，不含协议、端口、路径），脚本将其写入 `.env` 的 `DSH_TRUSTED_DOMAIN`，构建阶段以 root 在镜像内改写 DSH 浏览器与 Host API 两处 loopback 判定。**修改该值必须重新构建镜像**，`--skip-build` 下脚本拒绝启动。
5. **dsh 版本**：回车使用 Dockerfile 锁定版，可选 npm `latest` 正式版或 `next`/`alpha` 预览版。

随后脚本依次执行：静态校验（Compose 配置、Authelia 配置、`caddy validate` 语法、前置反代 ACL 策略）→ 目录权限、端口占用、代理连通性检查（直连模式跳过代理监听检测）→ 构建镜像 → 启动容器 → 健康检查 → listener 校验 → 输出结果与登录链接。关键安全检查不通过时以非零码退出。

健康检查轮询窗口约 240 秒。dsh 容器提前退出时立即判定失败，并输出退出码、3080 占用者与日志尾部；Authelia 与 Caddy 异常需等待窗口结束。

向导生成 Authelia 密钥、用户密码哈希与 Caddyfile，被改写文件备份为 `.bak`。脚本执行完毕后输出成功/失败摘要、检查计数与总耗时；提前中止或升级回滚走报错路径，不保证输出结果摘要。

## 进入方式

三种模式的内部链路相同（Caddy → Authelia → dsh，均经宿主回环），差异仅在公网入口与 TLS 终结位置。

| 条件 | 选型 |
|---|---|
| 有公网 IP，80 与 443 可达且空闲 | **2. 直连 80/443** |
| 有公网 IP，443 可达且空闲，80 被占用或被运营商封禁 | **1. 直连 443-only** |
| 无公网 IP，或 NAS 上已有 lucky / CF Tunnel | **3. 前置反代/Tunnel** |

Caddy 无法绑定已被占用的端口，443 亦被占用时只能选模式 3。运营商封禁 80 时选模式 1；脚本不会在模式 1 与 2 之间自动切换。向导将模式写入 `caddy/Caddyfile` 的标记行（`# dsh-nas-entry-mode: …`），后续每次部署据此校验端口与 listener。

<details>
<summary>各模式细节</summary>

**1. 直连 443-only**（向导默认）

- Caddy 仅监听 443，证书通过 TLS-ALPN-01 签发，仅需 443 可达
- 无 HTTP→HTTPS 跳转，浏览器须显式使用 `https://`
- DNS 的 A 或 AAAA 记录指向 NAS 即可；无公网 IPv4 时使用 IPv6 亦属直连
- 仅支持 DNS-01 验证的环境需自行配置 Caddy DNS provider
- 部署后 Caddy 须仅报告 `:443`

**2. 直连 80/443**

- Caddy 作为公网入口，80 用于 HTTP→HTTPS 跳转与 ACME HTTP-01 校验
- `dsh.<域名>`、`auth.<域名>` 的 A/AAAA 记录指向 NAS 公网地址（动态 IP 配 DDNS），路由器转发 80、443 至 NAS
- 部署后 Caddy 须仅报告 `:80`、`:443`

**3. 前置反代/Tunnel**

- Caddy 不接触公网（`auto_https off`）：同机模式监听 `127.0.0.1:13080`，跨机模式监听 NAS 局域网地址（如 `192.168.123.131:13080`）
- 前置入口配置公网 HTTPS listener 与证书（公网 TLS 在此终结），将 `dsh.<域名>` 与 `auth.<域名>` 转发至 Caddy。后端不得填写 dsh 的 3080：同机填 `http://127.0.0.1:13080`，跨机填 `http://192.168.123.131:13080`
- dsh 规则须启用 WebSocket；两条规则均须设置 `X-Forwarded-Proto: https`
- 跨机模式：向导选择「Lucky 在其它机器」并填写前置入口实际来源 IP；Caddy 在 `auth` 与 `dsh` 两个站点均以 `remote_ip` 仅放行该来源，NAS 防火墙仅放行该来源访问 TCP 13080。ACL 不得使用 X-Forwarded-For、`client_ip` 或 PROXY protocol
- 前置入口监听非标准公网端口（如 16666）时，向导中填写的端口须与其一致，该端口写入 Authelia URL 与访问地址
- 无需公网 IP。CF Tunnel 可使用同机回环模式，但 Tunnel 须运行于 host 网络（或可访问宿主回环）；否则其容器内 `127.0.0.1` 指向自身，无法连接 `127.0.0.1:13080`，此时改用 NAS 局域网地址绑定
- Lucky→Caddy 默认为明文 HTTP，须确保局域网可信；敏感环境应在网络层加密或隔离

</details>

## 登录

两层认证相互独立，均须通过。

**第一层：Authelia 双因素**

访问 `https://auth.<域名>[:公网端口]`，用户名 `admin`，密码为向导所设。首次登录按提示注册 TOTP。注册通知文件为 `authelia/data/notifications.txt`，仅用于注册，不是后续动态码。

**第二层：dsh 会话链接（一次性 token）**

dsh v0.1.2-alpha.1 起，Web 界面启用应用层浏览器会话认证：每次启动生成含 `?token=…` 的链接，脚本在结果摘要中输出，亦可随时获取：

```sh
./deploy.sh url        # 输出 https://dsh.<域名>[:公网端口]/?token=…
```

亦可从 NAS Docker 管理界面的 dsh 容器日志中取 `dsh web:` 行，拼接公网地址。

- 打开链接后签发 **30 天**（可配置）签名 cookie 并 303 跳转至无 token 地址。此后所有 Web 会话（含 `/api` RPC）均要求该 cookie，缺失或过期返回 401。
- 未携带 cookie 的 `/` 返回 401 属正常行为，compose 健康检查因此仅验证服务已响应：任意 HTTP 状态码均视为存活，不会误判 unhealthy。
- 各浏览器独立持有 cookie、独立计时，无痕窗口关闭即失效。cookie 密钥位于 `data/dsh/.credentials.yaml`，重启或重建容器不影响已签发 cookie。
- 链接过期后重新获取 token 并打开即可，Authelia 层不受影响。
- 使用早于 token 认证的 dsh 版本时，直接访问普通地址；`--cookie-max-age` 在该类版本上不生效，entrypoint 会探测 `--patch` 支持并输出警告，不影响容器启动。

修改有效期（**仅对新签发 cookie 生效**，已有浏览器需重新打开一次 token 链接）：

```sh
./deploy.sh --cookie-max-age 90      # 取值 1–3650 的整数天；不传该参数则使用 dsh 默认 30 天
```

`--setup` 向导亦会询问该项，可直接回车留空使用默认值。该值写入 `.env` 的 `DSH_COOKIE_MAX_AGE_DAYS`，由 entrypoint 生成 `--patch` overlay，**无需重建镜像**；`docker compose up -d dsh` 重建容器即生效。

## 日常运维

```sh
docker compose ps                    # 容器状态
docker compose logs -f dsh           # 日志
docker compose restart dsh           # 重启
./deploy.sh url                      # 获取当前会话链接
sudo ./deploy.sh --upgrade           # 升级 dsh（重建镜像，失败自动回滚）
```

> 使用 Compose V2 独立版（无 `docker compose` 插件）时，将上述命令替换为 `docker-compose`。

社区插件：

```sh
docker exec -it dsh dsh plugin --profile web add <插件包名>
docker exec -it dsh dsh plugin --profile web remove <插件名>
docker compose restart dsh
```

修改域名、入口模式或密码：重新执行 `./deploy.sh --setup`。

升级相关行为：

- 需要 root 权限。事务快照与升级锁位于 root-only 的 `/var/lib/dsh-nas-upgrade`，使用 `flock` 防并发，版本文件原子替换。
- 升级跳过配置向导，但仍询问一次反代域名 patch。版本选择发生在快照之后，回滚时旧版本号一并恢复。
- `127.0.0.1:3080` 被非预期进程或容器占用时，脚本列出占用者并询问处理方式：手动停止后重跑，或由脚本自动停止（容器 `stop`+`rm`，宿主进程 `kill`）。
- 升级前自动快照配置、`.env`、旧版本文件、旧镜像与容器状态。构建、启动、健康检查或 listener 校验任一失败，均恢复旧版本文件与旧镜像 tag。升级前三个容器中任一处于运行状态时，同时停止失败的新栈并重新启动旧栈；恢复失败以非零码退出。该机制为**单机回滚保护**，不具备零停机能力。
- 持久化数据不限于 `data/`：dsh 配置与会话在 `data/dsh/`，工作区在 `data/workspace/`，Authelia 的 SQLite 与通知在 `authelia/data/`，证书与 Caddy 状态在 `caddy/data/`、`caddy/config/`。重建容器不影响上述目录，备份时须全部覆盖。
- `sudo ./deploy.sh --latest` / `--alpha` 分别跟随 npm 正式版与 alpha 预览版，alpha dist-tag 不受 `latest` 发布节奏影响。升级 alpha 前备份 `data/dsh/`，升级后验证旧会话、Remote 与 WebSocket。

## 故障排查

| 现象 | 处理 |
|---|---|
| 向导拒绝继续 | 检查域名、密钥、用户哈希与 Caddyfile 标记；必要时执行 `./deploy.sh --setup` |
| 80 被占用 | 443 空闲则选 443-only；443 亦被占用则选前置反代 |
| 443-only 证书申请失败 | 检查 A/AAAA 记录、IPv6 防火墙与 443 可达性，并查看 `docker compose logs caddy` |
| 前置反代 502 或「后端访问被拒绝」 | 后端地址错误：同机为 `http://127.0.0.1:13080`，跨机为 `http://<NAS 局域网 IP>:13080`，不得填写 dsh 的 3080。同时检查 Lucky 实际来源 IP、Caddy `remote_ip` ACL 与 NAS 防火墙 |
| 部署报 Caddy listener 或 ACL 不符预期 | 同机检查 `default_bind 127.0.0.1`；跨机检查 `default_bind <NAS IP>`、两个站点的 `remote_ip <前置入口 IP>` 与 TCP 13080 防火墙。ACL 不得使用 X-Forwarded-For 或 `client_ip` |
| 未登录返回 401 或跳转循环 | 检查 Authelia URL、cookie domain、`X-Forwarded-Proto` 与 `forward_auth` 块 |
| dsh 反复重启或提示 profiles 不可写 | 执行 `sudo chown -R 1000:1000 data/dsh data/workspace`，确认目录挂载于可写本地盘 |
| 模型请求超时 | 检查 `.env` 的 `DSH_PROXY` 与代理监听地址，并查看 `docker compose logs dsh` |
| 流式输出或 WebSocket 异常 | 检查前置代理的 WebSocket 设置 |
| 从 SSH/SMB 拷入 `data/workspace` 的文件 agent 无法写入 | 拷入文件属主通常不是 UID 1000，容器内 agent 只读；执行 `sudo chown -R 1000:1000 data/workspace` 修正（该目录为容器专属，整目录递归安全）。在 dsh 网页新建的目录以 UID 1000 创建，无此问题 |
| 升级提示 3080 被占用 | 按提示选择：手动停止占用者后重跑，或由脚本自动停止（容器 `stop`+`rm`，宿主进程 `kill`）；端口释放后方可继续 |
| 升级失败且服务未恢复 | 脚本会尝试恢复快照、旧镜像与 dsh 服务；恢复亦失败时按提示检查 `Dockerfile`、`dsh:local` 与 Compose 状态 |
| `--skip-build` 被拒绝启动 | 现有 `dsh:local` 镜像与当前配置不一致（通常为反代域名或版本变更）。去掉 `--skip-build` 重新构建 |

## 安全清单

配置变更前逐项确认：

- 不得将 3080 暴露至局域网或公网，不得为 dsh 容器挂载 Docker socket。前者使认证可被绕过，后者将宿主 root 权限交付应用进程。
- 公网 TLS 须由 Caddy（直连模式）或前置代理/Tunnel 终结。跨机 Lucky→Caddy 的明文 HTTP 仅适用于可信局域网。
- 443-only 模式不执行 HTTP→HTTPS 跳转，须使用正确的 `https://` 地址访问。
- URL 中的一次性 token 不构成防护层，**既不替代回环监听，也不替代 Authelia**。升级至带 token 认证的 dsh 版本后，3080 仍须绑定回环，公网入口仍由 Caddy + Authelia 保护。
- 启用反代域名 patch 不改变上述任何一项：该 patch 仅影响浏览器权限面判定，认证仍由 Caddy + Authelia 承担。

<details>
<summary>为何不使用 Basic Auth</summary>

多数 NAS 反代教程采用「容器监听 0.0.0.0 + 反代挂 Basic Auth」，对可执行任意命令的 AI Agent 不足：

| 维度 | Basic Auth 方案 | 本方案 |
|---|---|---|
| 认证因子 | 单因子密码，浏览器常驻保存，每个请求携带明文凭据 | Authelia 双因素（TOTP）；会话上限 1 小时、无操作 5 分钟失效，「记住我」延长至 1 个月（可配置收紧） |
| 凭据泄露后果 | 密码即全部权限，无法按设备撤销 | 会话可单独登出；连续失败 5 次锁定 5 分钟 |
| 应用暴露面 | 容器监听 0.0.0.0，局域网可绕过反代直连应用 | dsh 仅监听 `127.0.0.1`，无绕过认证路径；部署后硬校验实际 listener |
| AI Agent 风险 | 常见教程为容器挂载 Docker socket，等价于交出宿主 root | 主容器无 socket、无 Docker CLI；升级经宿主机命令行，带快照与自动回滚 |

本模板的安全边界按「应用本身必然被攻破」设计：认证为独立的双因素层，应用本体仅绑定回环，宿主控制权保留在 NAS 命令行。

</details>

## 附录

### 全部参数

```sh
./deploy.sh                                  # 检查 + 构建 + 启动
./deploy.sh --setup                          # 重跑配置向导（域名、入口模式、密码）
./deploy.sh --skip-build                     # 以现有镜像启动，不构建
./deploy.sh --proxy-host 192.168.1.10:7890   # 指定构建与运行时代理
./deploy.sh --cookie-max-age 90              # 会话 cookie 有效期（天，无需重建镜像）
./deploy.sh url                              # 输出当前会话链接
sudo ./deploy.sh --upgrade                   # 升级（交互选择版本）
sudo ./deploy.sh --latest                    # 升级至 npm latest
sudo ./deploy.sh --alpha                     # 升级至 npm alpha 预览版
sudo ./deploy.sh update-script               # 升级本脚本（git 快进拉取）
./deploy.sh --help                           # 完整帮助（NO_COLOR=1 关闭颜色）
```

> **`update-script` 会丢弃未暂存的本地改动。** 该命令在执行 `git checkout -- .` 前不询问、不自动备份，手工修改过的脚本、Compose 文件或 Dockerfile 的未暂存改动将直接丢失，后续快进合并失败亦不恢复。未跟踪文件不受该 checkout 影响，但已暂存的改动可能导致合并失败。Caddyfile 与 Authelia 配置受 `skip-worktree` 保护，`.env` 与 `data/` 位于 `.gitignore`，均不受 checkout 影响。Dockerfile 的版本选择仅在合并成功后写回。手工修改过项目文件时，请先自行备份。

### 代理怎么填

- **构建阶段**（`docker compose build`）运行于独立网络命名空间，容器内 `127.0.0.1` 指向构建容器自身，**代理不可达**。构建使用的代理地址须为**构建容器可访问的地址**，通常为宿主可达的局域网地址（如 `192.168.1.10:7890`），且代理须允许局域网访问：Clash 需 `allow-lan: true` 并监听于局域网可达地址（如 `0.0.0.0:7890`）。代理位于其它主机亦可，只要构建容器可访问。
- 代理与 NAS 同机时，构建阶段仍须使用局域网 IP。脚本通过 `ip route get` 探测出口网卡 IP 作为建议值，兜底为过滤后的 `hostname -I`。填入 `127.0.0.1` 会提示构建不可达，该地址仅适用于 `--skip-build` 场景。
- **运行阶段**使用 host 网络，`127.0.0.1` 与局域网地址均可达。地址存于 `.env` 的 `DSH_PROXY`（空值表示直连），可用 `--proxy-host` 覆盖。
- `NO_PROXY` 至少包含 `127.0.0.1,localhost`；连接局域网内 Ollama 等服务时追加其 IP。
- 验证代理连通性（替换为实际地址）：

  ```sh
  curl -x http://192.168.1.10:7890 -sI https://api.deepseek.com
  ```

  该命令仅验证宿主到代理的连通性，不能替代构建容器的连通性验证。

### 构建与版本

- dsh 版本唯一来源为 `Dockerfile` 的 `ARG DSH_VERSION`。构建前从 npm registry 获取 `latest` 与 `next`/`alpha` 版本号，与锁定版一并列出供选择，选定后原子写回 Dockerfile。直连失败自动经代理重试；非交互或 registry 不可达时按锁定版继续，但 `--latest`/`--alpha` 获取 dist-tag 失败会直接报错退出，不回落至锁定版。`--skip-build` 不构建，故不询问。
- 版本查询不使用 npm 本地缓存，直接经 HTTP 读取 registry，附带 `Cache-Control: no-cache` 与时间戳参数，避免中间层按 URL 缓存返回旧版本。
- 首次构建需编译 native 依赖，耗时取决于 NAS CPU 与代理速度。构建上下文还须包含 `patch-trusted-domain.mjs`。
- 构建完成后脚本实测镜像：校验两个 bundle 是否已接受反代域名、镜像内 dsh 版本是否与 Dockerfile 一致，不一致则拒绝启动；`--skip-build` 启动前执行同一套校验。patch 在构建的 RUN 步骤内执行，输出被 BuildKit 折叠，需逐行查看时使用 `BUILDKIT_PROGRESS=plain docker compose build dsh`。
- `.dockerignore` 保证构建上下文不包含运行数据、密钥与部署脚本。构建阶段的 apt 与 npm 均经传入的代理；直连模式（`DSH_PROXY=` 空值）不注入代理参数。
- 容器日志使用 json-file 驱动并限额（`max-size: 50m`、`max-file: 3`），避免长期运行占满磁盘。

### 本项目镜像清理

部署、健康与安全检查全部通过后，脚本清理带标签 `io.github.gehennawu.dsh-nas.cleanup=dsh` 的悬空镜像。该标签仅写入最终 dsh 运行镜像，不写入基础镜像或中间构建阶段。

- 清理使用 `docker image prune`，不加 `-a`：带标签的镜像，以及被运行中或已停止容器引用的镜像均保留；Caddy、Authelia 及其它项目的镜像不在范围内。
- 未带标签的历史 dsh 镜像不会被补标或删除，首次更新后旧镜像可能继续占用空间。
- 标签为项目归属约定，不是权限边界，其它项目不得复用。同一宿主的多个 dsh-nas 副本共享该标签，属于同一清理范围。
- 清理失败仅输出警告，不撤销已成功的部署。前后数量统计可能受同时进行的 Docker 操作影响。
- `--skip-build` 不修改旧镜像；为补标签而立即重建或重启服务并无必要。

### 目录结构

```text
dsh-nas/
├── Dockerfile               # 构建 dsh 镜像；唯一版本来源 ARG DSH_VERSION
├── deploy.sh                # 部署/升级/回滚脚本
├── entrypoint.sh            # 容器入口：代理、DSH_HOME 自检、回环绑定启动
├── patch-trusted-domain.mjs # 反代域名 patch 脚本（构建上下文必需，是否执行取决于 DSH_TRUSTED_DOMAIN）
├── docker-compose.yml       # 三容器 host-network 编排与健康检查
├── .dockerignore            # 构建上下文排除运行数据、密钥和部署配置
├── caddy/
│   ├── Caddyfile            # 向导按入口模式生成，容器只读挂载
│   ├── data/                # 证书与运行数据，容器写入
│   └── config/              # 配置状态，容器写入
├── authelia/
│   ├── configuration.yml    # 宿主维护，容器只读挂载
│   ├── users_database.yml   # 用户库与 argon2id 哈希，容器只读挂载
│   └── data/                # SQLite 与通知文件，容器写入
├── data/
│   ├── dsh/                 # → /home/node/.dsh，UID 1000
│   └── workspace/           # → /workspace，UID 1000
└── .env                     # deploy.sh 生成的 DSH_PROXY 等
```

三个容器均使用 host 网络，容器内 `127.0.0.1` 即 NAS 宿主。

### 手动配置（不使用向导）

<details>
<summary>Authelia 与 Compose 手动步骤</summary>

1. 将 `authelia/configuration.yml`、`authelia/users_database.yml` 中的域名替换为真实域名。
2. 将 `CHANGE_ME_*` 密钥替换为随机值。
3. 生成 argon2id 密码哈希：

   ```sh
   docker run --rm authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password '你的密码'
   ```

4. 编写 Caddyfile。仓库内 `caddy/Caddyfile` 为**全注释占位模板**，三种模式各有一段被注释的示例可参考。须写出真实的活跃站点并包含 `# dsh-nas-entry-mode: <模式>` 标记行：仅修改域名不足以生效，向导以占位符是否被替换判断是否跳过。
5. 创建目录并修正属主：

   ```sh
   mkdir -p data/dsh data/workspace caddy/data caddy/config
   sudo chown -R 1000:1000 data/dsh data/workspace
   ```

   **不得**对整个 `data/` 递归 `chown`：`data/` 本身保持部署用户所有，容器仅需写入上述两个子目录。`authelia/data/`、`caddy/data/`、`caddy/config/` 由对应容器写入，`deploy.sh` 会执行实际写入测试。

6. 首次启动须带 `--build` 构建 dsh 镜像：

   ```sh
   docker compose --profile auth up -d --build
   ```

7. 按[登录](#登录)完成双因素注册与会话链接获取。

</details>

Authelia 登录会话与 dsh cookie 为两层独立认证：dsh cookie 的默认 30 天不替代 Authelia 会话时限，token 链接亦不替代用户名、密码与双因素。

## 许可证

MIT（见 [LICENSE](LICENSE)）。
