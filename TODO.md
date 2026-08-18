# dsh-nas 修复与通用化 TODO

> 当前项目不是通用 NAS 部署方案，而是面向 Linux + Docker Engine + Docker Compose V2 + Bash/GNU 工具 + host 网络 + 本地可写目录的部署模板。
>
> 网页升级当前不提供；不建议将 Docker socket 挂载到 dsh 主容器。
>
> ## 已确定的架构决策
>
> - **网页升级**：已移除「请求签发器 + systemd timer 处理器」链路（HMAC 对 root-only 权限模型冗余，且容器内网页无法安全触发宿主命令）；如重启该需求，按「宿主回环 agent 挂在 Caddy forward_auth 之后、只触发固定 deploy.sh --latest」的形态另行设计。在此之前只提供 SSH CLI 升级。
> - **Caddy 入口**：支持 80/443 直连、443-only 直连、前置反代/Tunnel + 内部端口三种模式。
> - **端口冲突**：部署脚本检测到冲突时交互询问，不静默切换；用户也可以退出后手动处理。
> - **网络范围**：当前版本只支持 Linux host 网络；暂不实现项目容器的 bridge 网络模式。
> - **升级回滚**：先实现基本事务回滚，不立即做蓝绿升级。
> - **Basic Auth**：删除无域名 Basic Auth 模式，只保留 Authelia 和前置反代/Tunnel 入口。
- **兼容性扩展**：按“先保证安全，再提供功能降级，最后扩展平台适配”的优先级回退；任何回退都必须显式提示并记录，不能静默降低安全边界。

## 已确定的兼容性回退策略

扩大可用范围不采用“一套配置适配所有 NAS”，而采用分层回退：

### Tier 0：安全基线（首要支持）

- Linux 主机。
- Rootful Docker Engine。
- Docker Compose V2（插件或独立 V2 二进制）。
- Linux host 网络。
- Bash、GNU `stat`、GNU `sed` 等基础工具。
- x86_64 或 ARM64。
- 项目目录位于本地可写文件系统，容器 UID 1000 可以实际写入。
- 使用域名 + Authelia，或使用已存在的前置反代/Tunnel。

### Tier 1：不改变安全边界的功能回退

按以下顺序选择：

1. **Caddy 入口**：80/443 直连 → 443-only 直连 → 前置反代/Tunnel + 内部端口。
2. **网页升级**：宿主受限升级代理 → 代理不可用时禁用网页升级，保留 SSH 命令行升级。
3. **Compose**：`docker compose` 插件 → Compose V2 独立二进制；拒绝 Compose V1。
4. **目录权限**：自动 `chown` → 用户手动修复属主/ACL；只要实际写入测试通过即可继续，写入测试失败必须停止。
5. **网络代理**：直连 → 用户明确配置的 HTTP/HTTPS 代理；构建代理和运行时代理分别验证，不能以其中一个成功冒充另一个成功。

### Tier 2：平台适配（完成 Tier 0/Tier 1 后再做）

- 自定义 Docker socket 路径。
- bridge 网络模式，以及 bridge 中访问宿主代理和前置 Tunnel 的方案。
- 非标准端口、容器名、Compose project name 和实例目录。
- 更广泛的 Linux NAS ACL、NFS、SMB 和特殊挂载场景。
- 更完整的架构构建支持，使用 `TARGETARCH`。
- rootless Docker 的单独适配评估；不能直接套用 rootful Docker 的 socket 权限逻辑。

### 明确的硬失败条件

以下情况不自动降级，也不伪造部署成功：

- 非 Linux/TrueNAS CORE 等不符合当前容器网络模型的环境。
- 没有 Docker Engine 或没有 Compose V2。
- 当前版本不支持 host 网络且 bridge 适配尚未完成。
- x86_64/ARM64 之外的架构，除非已经提供并验证对应构建产物。
- 项目目录、Caddy 数据目录或 Authelia 数据目录无法实际写入。
- 没有域名，也没有可用的前置反代/Tunnel（Basic Auth 已删除）。
- 443 被占用且没有可用的前置反代/Tunnel。
- 安全检查、配置校验或健康检查失败。

每次回退必须在终端和配置摘要中说明：选择了哪种模式、跳过了哪种能力、用户需要手动完成什么配置。

## 执行与验证规则

- 每个代码步骤只处理一个清晰范围，完成后立即运行最小验证。
- 与当前代码改动相互独立的检查、审计和测试，优先交给后台子代理并行执行。
- 子代理只做只读检查时不修改仓库；需要修改代码的步骤仍由主线单独完成，避免并发写冲突。
- 每轮结束先汇报变更和验证结果，再进入下一轮。

## 0. 先确定 Caddy 入口模式

项目应明确支持三种模式，不要把“80 被占用”简单等同于“只能 443-only”。

- [x] **直连 80/443 模式**
  - Caddy 监听 80 和 443。
  - 80 用于 HTTP → HTTPS 跳转，也可用于 ACME HTTP-01。
  - 部署前检查 80、443 均未被占用。
  - 适用于没有 NAS Web 面板或其他反代占用端口的环境。

- [x] **直连 443-only 模式**
  - Caddy 只监听 443。
  - 使用 `auto_https disable_redirects`。
  - 禁用 ACME HTTP-01，仅使用 TLS-ALPN-01，或明确配置 DNS-01。
  - 部署后确认 Caddy 没有监听 80。
  - 文档明确：访问必须使用 `https://`，不会提供 HTTP 自动跳转。
  - 仅适用于 443 空闲且 DNS/防火墙能正常访问 443 的环境。

- [x] **前置反代 / Tunnel 模式**
  - NAS 自带 Nginx/OpenResty、lucky 或 Cloudflare Tunnel 负责公网 TLS。
  - Caddy 只监听内部端口，例如 `127.0.0.1:13080`。
  - 前置代理将 `dsh.example.com` 和 `auth.example.com` 都转发到 Caddy。
  - 前置代理发送 `X-Forwarded-Proto: https`。
  - 文档说明 bridge 容器中的 `127.0.0.1` 不等于宿主机，需使用 host 网络、宿主可达地址或 host gateway。

## P0：安全止血

- [x] 删除 `docker-compose.yml` 中 `${DOCKER_GID:-0}` 的危险默认值。
- [x] 在未明确配置可信 Docker socket GID 时，禁止网页升级功能。
- [x] 移除 dsh 主容器的 `/var/run/docker.sock` 挂载，并关闭网页升级。
- [x] 已移除 `upgrade-request.json` + HMAC + systemd timer 的受限升级请求链路（`tools/`、`systemd/` 已删除）：该链路无可用的容器→宿主触发通路，HMAC 对 root-only 权限模型冗余。
- [ ] 网页升级如重新立项：实现宿主回环升级 agent，挂在现有 Caddy forward_auth（Authelia 2FA）之后，只允许触发 `deploy.sh --latest` 和读取状态，并补审计日志与速率限制；不引入 Docker socket、sudo 白名单或容器内宿主凭据。
- [x] 删除升级流程中的所有 `chmod 666`，特别是对 `.env` 的权限修改。
- [x] 保持 `.env` 为受限权限；升级早期快照和事务快照使用 `0600`，目录使用 `0700`。
- [x] 将升级快照、状态路径和旧容器 inspect 文件限制为 `0600/0700`；完整审计日志仍待后续。
- [ ] 对代理 URL、用户名、密码、token 和构建日志进行脱敏。
- [x] 版本文件和升级状态路径使用临时文件、fsync 和原子 rename，避免半写入。
- [ ] 后端增加网页升级的管理员/capability 检查，不能只依赖前端按钮隐藏（当前网页升级关闭）。
- [ ] 管理页接入后，增加网页升级审计日志、CSRF/Origin 校验和速率限制。
- [x] 不再按 `ancestor: dsh:local` 直接取第一个容器（旧网页升级路径已移除）。
- [x] 按固定容器名和 canonical 项目路径校验升级目标；Compose labels/镜像 digest 校验仍待后续增强。

## P0：部署失败必须硬失败

- [x] 将数据目录检查从“只检查目录属主”改为 UID 1000 实际写入和删除测试。
- [x] 测试 `data/dsh`、`data/dsh/profiles`、`data/dsh/profiles/node_modules` 的创建和写入。
- [x] 测试 `data/workspace` 的写入能力。
- [x] 测试 `caddy/data` 和 `caddy/config` 的写入能力。
- [x] 将 Authelia 配置/用户库改为只读挂载，单独测试 `authelia/data` SQLite 和通知文件目录的写入能力。
- [ ] 覆盖 NAS ACL、NFS root squash、SMB、只读挂载和 root-owned 子文件场景（需目标 NAS 矩阵）。
- [x] 权限修复或实际写入测试失败时增加 `FAIL` 并在启动 Compose 前退出。
- [x] dsh 未 healthy 时返回非零退出码。
- [x] Authelia 未 healthy 时返回非零退出码。
- [x] Caddy 配置加载失败或容器重启循环时返回非零退出码（通过 Caddy healthcheck）。
- [x] Caddy 预期端口未监听时返回非零退出码。
- [x] 不因存在旧的 `dsh`、`authelia` 或 `dsh-caddy` 容器而跳过全部端口检查。

## P0：配置和健康校验

- [x] 在部署启动前执行 `docker compose config --quiet`。
- [x] 在部署启动前使用实际 Caddy 镜像执行 `caddy validate --config ... --adapter caddyfile`（占位模板和三种代表性生成模式已验证）。
- [x] 使用 `authelia/authelia:4.39` 执行 `authelia config validate`（部署脚本在非升级模式启动前硬校验）。
- [x] 为 dsh 增加明确 healthcheck。
- [x] 为 Authelia 增加 `/api/health` healthcheck。
- [x] 为 Caddy 增加进程/admin API healthcheck。
- [x] 补充 Caddy 实际 listener 端口检查。
- [x] 验证 dsh 只监听 `127.0.0.1:3080`（部署后安全校验）。
- [x] 验证 Authelia 只监听 `127.0.0.1:9091`。
- [x] 验证 Caddy 只监听当前入口模式允许的端口和回环绑定（通过 admin API listener 检查）。
- [ ] 验证未登录访问 dsh 的 forward_auth/重定向链路。
- [ ] 在可用 Docker 环境中验证 TLS、WebSocket 和 SSE。

## P0：Caddy 端口语义

- [x] 让向导记录当前入口模式，而不是仅通过 grep 猜测模式。
- [x] 80/443 模式检查 80 和 443。
- [x] 443-only 模式显式设置 `auto_https disable_redirects`。
- [ ] 443-only 模式完成公网 ACME 验证，并在文档中明确使用 TLS-ALPN-01 或 DNS-01（当前配置依赖 Caddy 默认挑战选择）。
- [x] 443-only 模式启动后确认没有 `:80` listener。
- [x] 反代入口模式只检查内部端口，例如 13080。
- [x] 删除 Basic Auth 模式及其向导分支、模板和文档。
- [x] README 说明 80 被占用时的选择取决于 443 是否可用以及是否存在前置反代。
- [x] 为入口模式兼容回退输出明确的模式、风险和人工操作提示。

## P1：升级流程重构

- [x] 统一 dsh 版本来源，只保留 Dockerfile 的 `ARG DSH_VERSION` 一个真实来源。
- [x] 修复当前 `Dockerfile` 的 `rc.7` 与 Compose 的 `rc.6` 不一致（Compose 已删除重复版本来源）。
- [x] 升级前保存 Dockerfile、Compose、`.env`、旧镜像 ID 和运行容器配置。
- [x] 版本文件使用同目录临时文件、fsync 和原子替换。
- [x] `--latest` 修改版本失败时恢复旧版本文件。
- [x] 新容器启动失败或健康检查失败时触发旧版本/旧镜像恢复尝试，并等待校验 dsh、Authelia、Caddy healthy、listener 和 API（恢复失败仍硬失败）。
- [x] 只有确认容器/镜像实际发生变化时才执行旧栈 down/up，避免复用旧容器时误停原栈。
- [x] 将配置、版本和旧镜像快照纳入升级失败恢复流程；完整蓝绿/事务切换仍待后续加强。
- [x] Compose 启动失败明确返回非零，并在升级模式进入统一失败/回滚处理。
- [x] 构建、启动、健康检查和 listener 校验通过后才清除升级回滚保护。
- [x] 使用 GNU `flock` 锁覆盖升级检查、快照、版本写入、构建和切换全流程。
- [x] 升级模式复用 Compose/Caddy 启动前配置校验；当前升级保留配置并明确跳过 Authelia 内容校验。

## P1：Docker API 与升级权限

- [ ] 优先改为调用 Docker CLI，让 CLI 自动协商 Engine API 版本。
- [ ] 如果保留 Unix socket API，先请求 `/version` 并协商 API 版本。
- [ ] 对 Docker API query 参数使用 `encodeURIComponent`。
- [ ] 所有 Docker API 请求统一检查 HTTP 状态码。
- [ ] 清理 helper 容器前验证 `dsh-nas.upgrade=true` 等归属 label。
- [ ] 固定并校验 helper 镜像 digest。
- [x] 不使用通用 helper 容器；升级只由宿主机 CLI 以 root 执行（sudo deploy.sh --upgrade/--latest），不引入 Docker 管理容器。

## P1：代理和网络兼容性

- [ ] 修复部署检查“直连成功就不检查运行时代理”的逻辑。
- [ ] wget 兜底路径正确使用代理参数。
- [ ] 支持 IPv6 代理地址、认证代理 URL 和复杂 URL。
- [ ] 提供可配置的 `NO_PROXY`，不要固定为 `127.0.0.1,localhost`。
- [ ] 明确 host 网络、bridge 网络和 Tunnel 容器的差异。
- [ ] 支持自定义 Docker socket 路径（当前 dsh/网页升级不使用 Docker socket；仅在未来受限宿主代理需要时评估）。
- [ ] 参数化端口、容器名、Compose project name 和内部监听地址。
- [ ] 明确 TrueNAS CORE、非 Linux host 网络和 BusyBox-only 环境不在当前支持范围。
- [ ] 对 rootless Docker 做单独适配评估；在适配完成前明确拒绝或降级为无网页升级模式。

## P1：构建和供应链

- [ ] 使用 `TARGETARCH`，不要依赖构建阶段 `uname -m` 下载架构文件。
- [ ] 固定 `FROM` 基础镜像 digest。
- [ ] 固定或验证 apt 包版本。
- [ ] 对 Docker CLI 和 Compose 二进制执行 SHA256/签名校验。
- [ ] 使用 npm lockfile、制品完整性校验或可信 registry。
- [ ] 避免代理凭据进入 Docker build args、镜像层和构建日志。
- [ ] 记录镜像 digest、npm 包版本、CLI/Compose 版本和升级审计信息。

## P2：文档修正

- [x] 将标题从“通用 NAS 部署”改为“特定 Linux NAS 部署模板”。
- [x] 删除“任何支持 Docker 和 SSH 的机器都能用”等过度承诺。
- [x] 明确支持条件：Linux、Docker Engine、Compose V2、host 网络、本地可写目录、UID 1000 权限。
- [x] 明确不支持或需改造：TrueNAS CORE、rootless Docker、非 `/var/run/docker.sock`、不支持 host 网络的环境。
- [x] 修正“443-only”“80 被占用无碍”“公网只开 80/443”的表述。
- [x] 修正“自动回滚”和“构建失败后一定保持服务”的表述。
- [x] 说明前置 bridge Tunnel 容器不能直接访问宿主 `127.0.0.1`。
- [x] 删除 Basic Auth 和 Docker socket 网页升级的操作性文档。

## P2：测试矩阵

- [x] `bash -n deploy.sh entrypoint.sh`（已对当前安全止血步骤验证；后续配置变更需重复验证）。
- [x] `node --check` 插件 JavaScript（固化插件已移除，仓库不再分发插件代码；社区插件由 dsh CLI 自行管理）。
- [x] `docker compose config --quiet`（已对当前安全止血步骤验证；后续配置变更需重复验证）。
- [x] Caddy 80/443 模式配置适配和运行时 listener 测试（已完成配置适配；真实公网监听仍需目标 NAS 验证）。
- [x] Caddy 443-only 模式配置适配和无 80 listener 测试（TLS-ALPN 公网流程仍需目标 NAS 验证）。
- [x] Caddy 反代入口模式配置适配和 `X-Forwarded-Proto` 测试（真实前置代理链路仍需目标 NAS 验证）。
- [x] Authelia 4.39 配置校验和 `/api/health` 测试（当前运行环境已验证；目标 NAS 仍需部署后复核）。
- [ ] dsh 回环监听、健康检查和 WebSocket/SSE 测试（回环/健康已验证；WebSocket/SSE 仍待补测）。
- [x] 确认 dsh 不挂载 Docker socket，网页升级 endpoint 不执行 Docker 操作；旧 socket/GID 兼容场景不再作为支持目标。
- [x] 端口 80/443/13080/3080 的部署前 listener 冲突检查。
- [ ] 在目标 NAS 上执行 80/443/13080/3080 实际冲突矩阵测试。
- [ ] root-owned 子目录、ACL、NFS/SMB/只读目录测试（配置文件只读挂载和 Authelia 独立 data 目录已完成，目标 NAS 矩阵仍待执行）。
- [ ] x86_64 和 ARM64 构建测试。
- [ ] Docker Engine 不同 API 版本测试（当前部署脚本使用 Docker CLI/Compose，不提供 Docker API 直连升级接口；未来受限代理才需要专项测试）。

## 推荐默认策略

在没有更多环境信息时，建议默认采用：

1. 如果 80、443 都空闲：使用直连 80/443 模式。
2. 如果 80 被占用但 443 空闲：使用直连 443-only 模式。
3. 如果 443 被占用，或 NAS 已有反向代理/Tunnel：使用前置反代模式，Caddy 监听内部 13080。
4. 在网页升级改造成宿主受限升级代理前，默认关闭 Docker socket 升级能力。
