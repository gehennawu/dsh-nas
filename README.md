# dsh-nas：特定 Linux NAS 部署模板

这是一个面向 **Linux NAS** 的 dsh 部署模板：使用 Docker Engine、Docker Compose V2、Bash/GNU 工具和 host 网络，在 NAS 本地可写目录中运行 dsh、Authelia 与 Caddy。

它不是通用 NAS 方案，也不承诺适用于所有 NAS 品牌或容器平台。当前支持边界见[支持范围](#支持范围)。

## 支持范围

### 当前支持

- Linux 主机；
- rootful Docker Engine；
- Docker Compose V2（`docker compose` 插件或 V2 独立版）；
- Bash、GNU `sed`/`grep`/`awk`/`stat` 等常用工具；
- x86_64 和 ARM64（基础镜像及依赖能够在目标架构构建）；
- `network_mode: host`；
- 项目目录、`data/`、`authelia/data/` 和 `caddy/` 位于本地可写文件系统；
- 容器内 dsh 使用 UID 1000 运行，宿主目录必须允许 UID 1000 写入。

### 不在当前支持范围

- TrueNAS CORE、非 Linux Docker 主机；
- rootless Docker；
- 不支持 host 网络的容器平台；
- 仅提供 BusyBox、缺少 Bash/GNU 工具的环境；
- 不能使用 Docker Compose V2 的 NAS 管理界面；
- 把 Docker socket 暴露给 dsh 的网页升级方案；
- 没有域名且没有可用前置 TLS 代理的部署。

## 架构与安全边界

```text
公网浏览器
    │
    ├─ 直连 80/443 或 443-only ──> Caddy ──> Authelia 127.0.0.1:9091
    │                                      └─> dsh 127.0.0.1:3080
    │
    └─ 同机前置反代/Tunnel ──> Caddy 127.0.0.1:13080
                                         ├─> Authelia 127.0.0.1:9091
                                         └─> dsh 127.0.0.1:3080

 dsh 出站请求 ──> NAS 宿主代理（默认 127.0.0.1:7890）
```

- dsh、Authelia、Caddy 都使用 host 网络；容器内 `127.0.0.1` 就是 NAS 宿主机。
- dsh 由 [`entrypoint.sh`](entrypoint.sh) 强制使用 `--host 127.0.0.1`，不能让局域网绕过 Caddy 和 Authelia 直连 3080。
- `deploy.sh` 启动后检查 dsh 的实际 listener、Authelia 健康状态和 Caddy admin API listener；关键安全检查失败会返回非零退出码。
- dsh 主容器不挂载 `/var/run/docker.sock`，运行镜像不安装 Docker CLI/Compose。网页升级已关闭，避免应用进程获得宿主 Docker 控制权。
- 固化插件已移除：重启使用 `docker compose restart dsh`，升级使用宿主机 `deploy.sh --upgrade/--latest`，都在 NAS 命令行执行。
- 旧的无域名密码入口已删除。必须使用域名 + Authelia，或使用同一 NAS 上已经终结公网 TLS 的前置反代/Tunnel。

## 三种 Caddy 入口模式

配置向导会写入 `# dsh-nas-entry-mode: ...` 标记，部署脚本据此恢复模式并执行对应的端口、listener 校验。

### 1. 直连 80/443：`direct-80-443`

适合 DNS 的 A/AAAA 记录直接指向 NAS，且 80、443 都没有被其他服务占用的情况。

- Caddy 监听 80 和 443；
- HTTP 请求由 Caddy 自动跳转到 HTTPS；
- 可使用 ACME HTTP-01；
- 防火墙和公网入口需要放行 80、443；
- 部署后 Caddy admin API 必须只报告 `:80`、`:443`。

### 2. 直连 443-only：`direct-443-only`

适合 80 被 NAS 管理界面或其他服务占用，但 443 可以交给 Caddy 的情况。

- Caddy 只监听 443；
- 生成配置使用 `auto_https disable_redirects`，不会提供 HTTP → HTTPS 跳转；
- 访问必须显式使用 `https://`；
- 证书申请依赖 Caddy 可用的 ACME challenge，通常需要 TLS-ALPN-01；本模板不把 HTTP-01 当作可用前提。若你的环境只能使用 DNS-01，需要另外配置 Caddy DNS provider；
- 部署后 Caddy admin API 必须只报告 `:443`。

### 3. 同机前置反代/Tunnel：`front-proxy`

适合 NAS 上已经运行 lucky、OpenResty、Cloudflare Tunnel 等公网 TLS 入口的情况。

- 前置入口负责公网证书和 HTTPS；
- Caddy 使用 `auto_https off`，只监听 `127.0.0.1:13080`；
- 前置入口必须把 `dsh.<domain>` 和 `auth.<domain>` 都转发到 Caddy，并保留/设置 `X-Forwarded-Proto: https`；
- 前置入口必须与 Caddy 位于同一 NAS，或明确具备访问 NAS 回环地址的能力；普通 bridge 网络容器里的 `127.0.0.1` 不是宿主机，因此不应直接照抄该地址；
- 部署后非回环 listener（例如 `:13080`、`0.0.0.0:13080` 或 NAS 局域网 IP）会硬失败，不能为了兼容性静默暴露内部入口；
- 公网端口会写入 Authelia URL 和最终访问提示，例如 `https://dsh.example.com:16666`。

如果 443 也被其他服务占用，不能选择直连模式，必须先把公网 TLS 入口交给同机前置代理/Tunnel，并让 Caddy 使用独立内部端口。

## 前置条件

1. **出站代理**：NAS 宿主上有 HTTP/mixed 代理，默认 `127.0.0.1:7890`。验证：

   ```sh
   curl -x http://127.0.0.1:7890 -sI https://api.deepseek.com | head -n 1
   ```

   如果代理不在 NAS 本机，使用宿主可达地址，例如 `./deploy.sh --proxy-host 192.168.1.10:7890`，并确保代理允许局域网访问。

2. **域名和 DNS**：需要 `dsh.<domain>` 与 `auth.<domain>` 两个主机名。直连模式将它们解析到 NAS；前置反代模式将它们解析到公网 TLS 入口。

3. **本地目录**：项目目录和运行数据不能位于只读挂载、无法执行 `chown` 的共享目录或不支持 root 写入的远程文件系统。运行数据由 UID 1000 写入（见下方说明）。容器内 UID 1000 需要写入：

   ```sh
   mkdir -p data/dsh data/workspace \
     caddy/data caddy/config
   sudo chown -R 1000:1000 data/dsh data/workspace
   ```

   不要对整个 `data/` 做 `chown -R`：`data/` 本身保持部署用户所有，容器只需要写入上面两个子目录。

   Authelia/Caddy 配置文件由宿主机维护并以只读方式挂载；Authelia 的 SQLite/通知数据放在 `authelia/data/`，Caddy 运行数据放在 `caddy/data/` 和 `caddy/config/`，这些数据目录必须能被对应容器写入。`deploy.sh` 会检查目录；权限无法修复时应先在宿主机处理，不要直接跳过安全检查。

4. **SSH 和 Docker 权限**：能在 NAS 上执行 Docker 命令，并且当前用户可以运行 Docker Engine。

## 快速部署

推荐只使用部署脚本，因为它会在启动 Compose 前执行 Compose 配置、Authelia 配置和 Caddyfile 语法检查，再执行目录、端口、健康状态和 listener 安全检查：

```sh
cd dsh-nas
chmod +x deploy.sh
./deploy.sh
```

首次运行时向导会：

1. 写入出站代理地址到 `.env`；
2. 询问根域名、证书邮箱和 Authelia admin 密码；
3. 让你选择三种 Caddy 入口模式；
4. 自动生成 Authelia 密钥、用户密码哈希和 Caddyfile；
5. 为被改写的配置保留 `.bak` 备份；
6. 检查文件、目录、端口、代理连通性和 Compose 配置；
7. 构建并启动 dsh、Authelia、Caddy；
8. 等待健康检查，并验证 dsh、Authelia、Caddy 的实际 listener。

### 升级方式和网页升级替代方案

当前**不推荐也不提供 dsh 网页直接升级**。不要给 dsh 容器挂载 Docker socket，也不要让通用升级容器拥有整个项目目录的 root 可写权限；Docker socket 基本等价于宿主机 root 控制权。

推荐顺序：

1. **首选：SSH + 宿主机脚本升级**
   ```sh
   sudo ./deploy.sh --upgrade
   sudo ./deploy.sh --latest
   ```
   这是当前实现和推荐方式。脚本运行在 NAS 宿主机上，使用 `flock`、原子版本文件、旧镜像快照、健康/listener 校验和失败恢复。升级需要 root：事务快照和升级锁目录必须为 root:0700，非 root 用户无法执行升级。

2. **需要网页按钮时：单独的受限升级代理**

   可以单独运行一个升级代理，但它不应是“拥有 Docker socket 的通用 Docker 管理器”。更安全的设计是：
   - 代理只绑定 `127.0.0.1` 或管理网，不暴露公网；
   - 只接受管理员认证后的固定升级命令；
   - 只允许固定项目目录、固定 Compose project、固定服务名 `dsh`；
   - 只允许 SemVer 版本规则和固定 registry；
   - 只允许 `build dsh`、`up/restart`、健康检查、回滚等白名单动作；
   - 不允许任意 Docker API、任意宿主路径、任意镜像、任意 shell；
   - 代理本身使用宿主机 systemd/sudo 最小权限，或通过一个极窄的 Unix socket/helper 执行器；
   - 必须有 CSRF/Origin 校验、速率限制、审计日志、并发锁和可验证的回滚状态。

   如果只能通过 Docker socket 控制 Docker，风险仍然接近宿主 root；这类容器不能作为默认推荐方案。**单独开一个普通升级 Docker 并不能自动变安全**，关键是权限和命令白名单。

   如果未来实现网页升级，推荐形态是：宿主机跑一个小 agent，只绑定 `127.0.0.1`，由 Caddy 挂在现有 forward_auth（Authelia 双因素）之后；agent 只允许触发固定的 `deploy.sh --latest` 和读取状态，认证由 Authelia 承担。dsh 容器内的网页进程不跨容器边界调用宿主命令，也不引入请求文件、HMAC 签名或 sudo 白名单等中间层。在此之前，请使用 SSH 命令行升级。

### 常用参数

```sh
./deploy.sh --skip-build                    # 使用已有 dsh 镜像启动
./deploy.sh --proxy-host 192.168.1.10:7890  # 设置构建和运行时代理
./deploy.sh --setup                          # 重新选择域名、入口或密码
sudo ./deploy.sh --upgrade                   # 使用 Dockerfile 当前版本重建 dsh（需 root）
sudo ./deploy.sh --latest                    # 查询 npm latest，只更新 Dockerfile 版本并重建（需 root）
```

`--upgrade` 和 `--latest` 会跳过配置向导，并在构建前保存 Dockerfile、Compose、`.env`、Caddy/Authelia 配置、旧 dsh 镜像 ID 和运行容器配置。升级要求已有可恢复的 `dsh:local` 镜像，并使用 GNU `flock` 防止并发升级。版本文件采用同目录临时文件、fsync 和原子替换；构建、启动、健康检查或 listener 校验失败时，脚本会尝试恢复旧版本文件、旧镜像 tag 和 dsh 服务，并等待验证 dsh、Authelia、Caddy healthy、listener 和 API；只有确认容器或镜像实际发生切换时才停止并重启旧栈。恢复失败仍会以非零退出。该流程是受限的单机回滚保护，不是蓝绿发布；运行数据位于 `data/`，不会因正常重建而删除。

不要在 Windows Git Bash 中运行部署脚本；端口、属主和 `chown` 语义必须由 NAS 的 Linux shell 提供。

## 构建和版本

- dsh 版本唯一来源是 [`Dockerfile`](Dockerfile) 构建阶段的 `ARG DSH_VERSION`。
- `docker-compose.yml` 不再重复声明 dsh 版本，也不向 dsh 容器注入 Docker socket。
- 构建阶段的 apt/npm 下载使用部署脚本传入的 `HTTP_PROXY`/`HTTPS_PROXY`。NAS 上的 `127.0.0.1` 对构建容器不是宿主机，代理通常需要填写 NAS 局域网地址。
- 运行阶段使用 `.env` 中的 `DSH_PROXY`；`NO_PROXY` 至少应包含 `127.0.0.1,localhost`。
- 首次构建需要编译 native 依赖，耗时取决于 NAS CPU 和代理速度。

## Authelia 首次配置

向导会自动完成以下工作；手动配置时参考：

1. 把 `authelia/configuration.yml`、`authelia/users_database.yml` 和 Caddyfile 中的域名替换为真实域名；首次部署前创建 `authelia/data/`；
2. 用随机值替换 `CHANGE_ME_*` 密钥；
3. 生成 argon2id 密码哈希：

   ```sh
   docker run --rm authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password '你的密码'
   ```

4. 使用 `docker compose --profile auth up -d` 启动 Authelia；
5. 第一次登录后按提示注册 TOTP。文件通知器会把初始验证码写到 `authelia/data/notifications.txt`，读取后应妥善保护或清理该文件。

## 前置反代配置要点

以同一 NAS 上的 lucky 为例：

1. 配置公网 HTTPS listener 和证书；
2. 建立两条规则：
   - `dsh.<domain>` → `http://127.0.0.1:13080`；
   - `auth.<domain>` → `http://127.0.0.1:13080`；
3. dsh 规则开启 WebSocket；
4. 两条规则都设置 `X-Forwarded-Proto: https`；
5. 让向导中的公网端口与 lucky 实际监听端口一致。

如果是 Cloudflare Tunnel 或其他容器化前置入口，应确认它使用 host 网络或其他明确的宿主访问方式；bridge 网络中的 `127.0.0.1:13080` 通常会指向前置容器自身。

## 使用与运维

```sh
docker compose ps
docker compose logs -f dsh
docker compose logs -f authelia
docker compose logs -f caddy
docker compose restart dsh
```

重启 dsh 使用 `docker compose restart dsh`（在 NAS 宿主机执行）。社区插件使用 dsh CLI 管理：

```sh
docker exec -it dsh dsh plugin --profile web add <插件包名>
docker compose restart dsh
```

删除插件也应使用 CLI，避免 profile 的依赖和 bundle 注册表只删除一半：

```sh
docker exec -it dsh dsh plugin --profile web remove <插件名>
docker compose restart dsh
```

## 常见问题

| 现象 | 处理 |
|---|---|
| 配置向导拒绝继续 | 检查域名、密钥、用户哈希和 Caddyfile 模式标记；必要时运行 `./deploy.sh --setup`。 |
| 80 被占用 | 如果 443 空闲，选择 443-only；如果 443 也被占用，使用同机前置反代/Tunnel。 |
| 443-only 证书申请失败 | 检查 A/AAAA、IPv6 防火墙和 443 可达性；查看 `docker compose logs caddy`。该模式不提供 80 跳转。 |
| 前置反代模式打不开 | 确认 dsh/auth 两个域名都转发到 `127.0.0.1:13080`，开启 WebSocket，并设置 `X-Forwarded-Proto: https`。 |
| 部署报告 Caddy 非回环 listener | 不要忽略；检查 Caddyfile 的 `default_bind 127.0.0.1` 和是否加载了旧配置。 |
| 未登录时出现 401 或跳转循环 | 检查 Authelia URL、cookie domain、前置代理的 `X-Forwarded-Proto` 和 Caddy `forward_auth` 块。 |
| dsh 反复重启或 profiles 不可写 | 在宿主机执行 `sudo chown -R 1000:1000 data/dsh data/workspace`，检查挂载是否位于可写本地目录。 |
| 模型请求超时 | 检查 `DSH_PROXY`、宿主代理监听地址和 `docker compose logs dsh`。 |
| 流式输出或 WebSocket 异常 | 检查前置代理是否启用 WebSocket；不要删除 Caddy 的 `reverse_proxy` 配置。 |
| CLI 升级失败 | 脚本会尝试恢复事务快照、旧镜像和 dsh 服务；若恢复报告失败，保留事务目录并按提示检查 `Dockerfile`、`dsh:local` 和 Compose 状态。 |
| 想使用网页升级 | 当前不提供。请通过 NAS SSH 运行 `./deploy.sh --upgrade` 或 `--latest`。 |

## 安全要求

- 不要把 dsh 的 3080 暴露到局域网或公网；它没有独立认证层。
- 不要给 dsh 容器挂载 Docker socket；Docker socket 等价于接近宿主 root 的控制权。
- 不要用未加密的公网 HTTP 前置入口；公网 TLS 必须由 Caddy 直连模式或同机前置代理/Tunnel 终结。
- 保持 `authelia/`、`.env`、Caddy 证书数据和通知文件的宿主权限最小化。
- 443-only 不会自动把 HTTP 跳转到 HTTPS；用户必须使用正确的 `https://` URL。

## 目录结构

```text
dsh-nas/
├── Dockerfile
├── deploy.sh
├── entrypoint.sh
├── docker-compose.yml
├── caddy/
│   ├── Caddyfile
│   ├── data/       # Caddy 证书和运行数据
│   └── config/     # Caddy 配置状态
├── authelia/
│   ├── configuration.yml       # root-owned，容器只读挂载
│   ├── users_database.yml      # root-owned，容器只读挂载
│   └── data/                   # SQLite/通知文件，由 Authelia 写入
├── data/
│   ├── dsh/        # → /home/node/.dsh，UID 1000
│   └── workspace/  # → /workspace，UID 1000
└── .env            # deploy.sh 生成的 DSH_PROXY
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 构建 dsh 镜像；唯一的 dsh 版本来源是 `ARG DSH_VERSION`。 |
| `entrypoint.sh` | 设置代理、检查 DSH_HOME 可写性，并以 `127.0.0.1` 启动 dsh。 |
| `docker-compose.yml` | dsh、Authelia、Caddy 的 host-network Compose V2 编排和健康检查；dsh 无 Docker socket。 |
| `caddy/Caddyfile` | 向导生成的三种入口模式、forward_auth 和反向代理配置。 |
| `authelia/configuration.yml` | Authelia 4.39 配置；容器只读挂载。 |
| `authelia/users_database.yml` | Authelia 用户库和 argon2id 密码哈希；容器只读挂载。 |
| `authelia/data/` | Authelia SQLite 和通知文件，由容器写入。 |

## 许可证

MIT（见 [LICENSE](LICENSE)）。
